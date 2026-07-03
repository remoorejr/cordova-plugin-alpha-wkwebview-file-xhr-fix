/*
 * Copyright (c) 2026 Alpha Software.
 *
 * The Universal Permissive License (UPL), Version 1.0
 *
 * Subject to the condition set forth below, permission is hereby granted to any person obtaining a copy of this
 * software, associated documentation and/or data (collectively the "Software"), free of charge and under any and
 * all copyright rights in the Software, and any and all patent rights owned or freely licensable by each
 * licensor hereunder covering either (i) the unmodified Software as contributed to or provided by such licensor,
 * or (ii) the Larger Works (as defined below), to deal in both
 *
 * (a) the Software, and
 *
 * (b) any piece of software and/or hardware listed in the lrgrwrks.txt file if one is included with the Software
 * (each a "Larger Work" to which the Software is contributed by such licensors),
 *
 * without restriction, including without limitation the rights to copy, create derivative works of, display,
 * perform, and distribute the Software and make, use, sell, offer for sale, import, export, have made, and
 * have sold the Software and the Larger Work(s), and to sublicense the foregoing rights on either these or other
 * terms.
 *
 * This license is subject to the following condition:
 *
 * The above copyright notice and either this complete permission notice or at a minimum a reference to the UPL
 * must be included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
 * TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 * CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

#import "CDVAlphaSessionSchemeHandler.h"
#import <objc/runtime.h>

static NSString * const kAlphaSessionScheme = @"alpha-session";
static NSString * const kAlphaSessionSchemePrefix = @"alpha-session://";
static NSString * const kAlphaSessionRequiredPathToken = @"/A5SessionFile/";

// config.xml <preference> that toggles verbose per-request diagnostics at runtime.  Cordova lowercases
// preference keys in the settings dictionary, so the lookup below is done against the lowercase form.
static NSString * const kAlphaSessionDiagnosticsPreference = @"AlphaSessionDiagnostics";

NS_ASSUME_NONNULL_BEGIN

API_AVAILABLE(ios(11.0))
@interface CDVAlphaSessionSchemeHandler ()

@property (nonatomic, strong) NSURLSession *urlSession;

// Maps an in-flight NSURLSessionTask to the WKURLSchemeTask that requested it.
@property (nonatomic, strong) NSMapTable<NSURLSessionTask *, id<WKURLSchemeTask>> *taskMap;

// The set of scheme tasks that are still active (i.e. not stopped by WebKit).  Used to guard
// against messaging a scheme task after it has been stopped, which would crash the app.
@property (nonatomic, strong) NSMutableSet<id<WKURLSchemeTask>> *activeSchemeTasks;

// Guards taskMap and activeSchemeTasks, both of which are touched from the session delegate
// queue and the main queue.
@property (nonatomic, strong) NSLock *lock;

// Verbose per-request diagnostics toggle, sourced from the config.xml AlphaSessionDiagnostics
// preference when the WKWebView configuration is built.  Logs cookie names/counts only, never values.
@property (atomic, assign) BOOL diagnosticLoggingEnabled;

// Cookies captured from raw XHR responses (see -rememberCookies:), keyed by name/domain/path.  Used
// as the highest-priority cookie source so cross-site / Partitioned session cookies are available on
// the very first alpha-session request.  Guarded by `rememberedCookiesLock`.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSHTTPCookie *> *rememberedCookies;
@property (nonatomic, strong) NSLock *rememberedCookiesLock;

// The learned Alpha session cookie identity, discovered by matching a Set-Cookie value against the
// X-A5WSessionId response header.  Once known, the X-A5WSessionId header alone keeps the remembered
// session cookie value current.  All guarded by `rememberedCookiesLock`.
@property (nonatomic, copy, nullable) NSString *sessionCookieName;
@property (nonatomic, copy, nullable) NSString *sessionCookieDomain;
@property (nonatomic, copy, nullable) NSString *sessionCookiePath;

@end

@implementation CDVAlphaSessionSchemeHandler

#pragma mark - Lifecycle

+ (instancetype)sharedHandler {
    static CDVAlphaSessionSchemeHandler *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[CDVAlphaSessionSchemeHandler alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        configuration.HTTPShouldSetCookies = YES;
        configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
        configuration.HTTPCookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];

        _urlSession = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
        _taskMap = [NSMapTable strongToStrongObjectsMapTable];
        _activeSchemeTasks = [NSMutableSet set];
        _lock = [[NSLock alloc] init];
        _rememberedCookies = [NSMutableDictionary dictionary];
        _rememberedCookiesLock = [[NSLock alloc] init];
    }
    return self;
}

#pragma mark - Scheme registration (method swizzle)

/**
 * Swizzle -[CDVWebViewEngine createConfigurationFromSettings:] so we can attach the alpha-session
 * scheme handler to the WKWebViewConfiguration before the Cordova engine builds the WKWebView.
 * This is the only lifecycle point at which a custom scheme handler can be registered.
 */
+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [self installConfigurationSwizzle];
    });
}

+ (void)installConfigurationSwizzle {
    Class engineClass = NSClassFromString(@"CDVWebViewEngine");
    if (engineClass == Nil) {
        NSLog(@"[AlphaSession] CDVWebViewEngine not found; alpha-session scheme not registered.");
        return;
    }

    SEL originalSelector = NSSelectorFromString(@"createConfigurationFromSettings:");
    Method originalMethod = class_getInstanceMethod(engineClass, originalSelector);
    if (originalMethod == NULL) {
        NSLog(@"[AlphaSession] createConfigurationFromSettings: not found; alpha-session scheme not registered.");
        return;
    }

    SEL swizzledSelector = @selector(alpha_createConfigurationFromSettings:);
    Method swizzledMethod = class_getInstanceMethod([self class], swizzledSelector);
    if (swizzledMethod == NULL) {
        NSLog(@"[AlphaSession] Swizzled method missing; alpha-session scheme not registered.");
        return;
    }

    BOOL added = class_addMethod(engineClass,
                                 swizzledSelector,
                                 method_getImplementation(swizzledMethod),
                                 method_getTypeEncoding(swizzledMethod));
    if (!added) {
        NSLog(@"[AlphaSession] Could not add swizzled method; alpha-session scheme not registered.");
        return;
    }

    Method addedMethod = class_getInstanceMethod(engineClass, swizzledSelector);
    method_exchangeImplementations(originalMethod, addedMethod);
    NSLog(@"[AlphaSession] Installed alpha-session configuration hook on CDVWebViewEngine.");
}

/**
 * Runs with `self` being the CDVWebViewEngine instance.  After the implementations have been
 * exchanged, the call below resolves to the engine's ORIGINAL createConfigurationFromSettings:.
 */
- (WKWebViewConfiguration *)alpha_createConfigurationFromSettings:(NSDictionary *)settings {
    WKWebViewConfiguration *configuration = [self alpha_createConfigurationFromSettings:settings];

    if (configuration != nil) {
        if (@available(iOS 11.0, *)) {
            CDVAlphaSessionSchemeHandler *handler = [CDVAlphaSessionSchemeHandler sharedHandler];
            handler.diagnosticLoggingEnabled = [CDVAlphaSessionSchemeHandler diagnosticsEnabledFromSettings:settings];
            if ([configuration urlSchemeHandlerForURLScheme:kAlphaSessionScheme] == nil) {
                [configuration setURLSchemeHandler:handler
                                      forURLScheme:kAlphaSessionScheme];
                NSLog(@"[AlphaSession] Attached alpha-session scheme handler to WKWebViewConfiguration (diagnostics: %@).",
                      handler.diagnosticLoggingEnabled ? @"on" : @"off");
            }
        }
    }

    return configuration;
}

/**
 * Reads the AlphaSessionDiagnostics config.xml preference from the Cordova settings dictionary.
 * Cordova stores preference keys lowercased, so the lookup is case-insensitive.  Accepts the usual
 * truthy strings ("true", "yes", "1").  Defaults to NO when the preference is absent.
 */
+ (BOOL)diagnosticsEnabledFromSettings:(nullable NSDictionary *)settings {
    if (![settings isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    id value = settings[kAlphaSessionDiagnosticsPreference];
    if (value == nil) {
        value = settings[[kAlphaSessionDiagnosticsPreference lowercaseString]];
    }
    if (![value isKindOfClass:[NSString class]]) {
        return NO;
    }

    NSString *normalized = [(NSString *)value lowercaseString];
    return [normalized isEqualToString:@"true"]
        || [normalized isEqualToString:@"yes"]
        || [normalized isEqualToString:@"1"];
}

#pragma mark - WKURLSchemeHandler

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask API_AVAILABLE(ios(11.0)) {
    NSURLRequest *originalRequest = urlSchemeTask.request;
    NSURL *targetURL = [self reconstructTargetURLFromSchemeURL:originalRequest.URL];

    if (targetURL == nil) {
        if (self.diagnosticLoggingEnabled) {
            NSLog(@"[AlphaSession] Rejected request; invalid alpha-session URL: %@", originalRequest.URL.absoluteString);
        }
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain
                                             code:NSURLErrorUnsupportedURL
                                         userInfo:@{ NSLocalizedDescriptionKey: @"Invalid alpha-session URL." }];
        [self failSchemeTask:urlSchemeTask withError:error];
        return;
    }

    if (self.diagnosticLoggingEnabled) {
        NSLog(@"[AlphaSession] Scheme fired: %@ -> %@ (%@)",
              originalRequest.URL.absoluteString,
              targetURL.absoluteString,
              originalRequest.HTTPMethod.length > 0 ? originalRequest.HTTPMethod : @"GET");
    }

    // Mark the scheme task active up-front so a stopURLSchemeTask: that arrives before the
    // asynchronous cookie fetch completes is observed and the request is abandoned safely.
    [self.lock lock];
    [self.activeSchemeTasks addObject:urlSchemeTask];
    [self.lock unlock];

    // WKWebView keeps its session cookie in its own WKHTTPCookieStore, which is NOT the same as
    // NSHTTPCookieStorage.sharedHTTPCookieStorage that NSURLSession reads from.  On a fresh session
    // the shared store has not yet been populated, so the first native subresource load would go out
    // without the session cookie.  Fetch the cookies from the WebView's own store and attach them
    // manually so the very first request carries the correct session cookie.
    WKHTTPCookieStore *cookieStore = webView.configuration.websiteDataStore.httpCookieStore;
    [cookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        [self startProxyForSchemeTask:urlSchemeTask
                            targetURL:targetURL
                      originalRequest:originalRequest
                       webViewCookies:cookies];
    }];
}

/**
 * Builds and starts the proxied NSURLSession request for a scheme task, injecting the cookies that
 * apply to the target URL.  Runs on the main thread from the WKHTTPCookieStore completion handler.
 */
- (void)startProxyForSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask
                     targetURL:(NSURL *)targetURL
               originalRequest:(NSURLRequest *)originalRequest
                webViewCookies:(NSArray<NSHTTPCookie *> *)webViewCookies API_AVAILABLE(ios(11.0)) {
    // The scheme task may have been stopped while the cookies were being fetched.
    if (![self isSchemeTaskActive:urlSchemeTask]) {
        if (self.diagnosticLoggingEnabled) {
            NSLog(@"[AlphaSession] Scheme task stopped before proxy start: %@", targetURL.absoluteString);
        }
        return;
    }

    NSMutableURLRequest *proxyRequest = [NSMutableURLRequest requestWithURL:targetURL];
    proxyRequest.HTTPMethod = originalRequest.HTTPMethod.length > 0 ? originalRequest.HTTPMethod : @"GET";
    // Cookies are injected manually below from the WebView's own cookie store, so disable the
    // session's automatic (shared-storage) cookie handling to avoid conflicting/stale cookies.
    [proxyRequest setHTTPShouldHandleCookies:NO];

    // Forward a safe subset of headers from the original request so that conditional and range
    // loads (large images, revalidation) continue to work.
    NSArray<NSString *> *forwardHeaders = @[ @"Range", @"Accept", @"Accept-Language", @"If-None-Match", @"If-Modified-Since" ];
    NSDictionary<NSString *, NSString *> *originalHeaders = originalRequest.allHTTPHeaderFields;
    for (NSString *headerName in forwardHeaders) {
        NSString *value = originalHeaders[headerName];
        if (value.length > 0) {
            [proxyRequest setValue:value forHTTPHeaderField:headerName];
        }
    }

    // The session cookie is written to NSHTTPCookieStorage.sharedHTTPCookieStorage by the file-xhr
    // plugin's NSURLSession as soon as the login/session XHR completes, but it is only synced into the
    // WebView's WKHTTPCookieStore on a LATER XHR completion.  Cross-site / Partitioned (CHIPS) cookies
    // such as Alpha's A5WSessionId may not be committed to either store on the first response at all,
    // so cookies captured directly from the raw XHR response (-rememberCookies:) take top priority.
    NSArray<NSHTTPCookie *> *rememberedCookies = [self rememberedCookiesSnapshot];
    NSArray<NSHTTPCookie *> *webViewStoreCookies = webViewCookies ?: @[];
    NSArray<NSHTTPCookie *> *sharedStoreCookies = [NSHTTPCookieStorage sharedHTTPCookieStorage].cookies ?: @[];
    NSArray<NSHTTPCookie *> *mergedCookies = [self mergeCookieSources:@[
        @[ rememberedCookies, @"xhrResponse" ],
        @[ webViewStoreCookies, @"WKHTTPCookieStore" ],
        @[ sharedStoreCookies, @"sharedHTTPCookieStorage" ],
    ]];

    NSArray<NSHTTPCookie *> *applicableCookies = [self cookiesFrom:mergedCookies applicableToURL:targetURL];
    if (applicableCookies.count > 0) {
        NSDictionary<NSString *, NSString *> *cookieHeaders = [NSHTTPCookie requestHeaderFieldsWithCookies:applicableCookies];
        NSString *cookieHeader = cookieHeaders[@"Cookie"];
        if (cookieHeader.length > 0) {
            [proxyRequest setValue:cookieHeader forHTTPHeaderField:@"Cookie"];
        }
    }

    if (self.diagnosticLoggingEnabled) {
        NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:applicableCookies.count];
        for (NSHTTPCookie *cookie in applicableCookies) {
            [names addObject:cookie.name];
        }
        NSLog(@"[AlphaSession] Attaching %lu cookie(s) [%@] to %@ (remembered: %lu, webViewStore: %lu, sharedStore: %lu)",
              (unsigned long)applicableCookies.count,
              [names componentsJoinedByString:@", "],
              targetURL.absoluteString,
              (unsigned long)rememberedCookies.count,
              (unsigned long)webViewCookies.count,
              (unsigned long)[NSHTTPCookieStorage sharedHTTPCookieStorage].cookies.count);
    }

    NSURLSessionDataTask *dataTask = [self.urlSession dataTaskWithRequest:proxyRequest];

    [self.lock lock];
    // Re-check under the lock: a stop that raced with the cookie fetch may have removed the task.
    if (![self.activeSchemeTasks containsObject:urlSchemeTask]) {
        [self.lock unlock];
        return;
    }
    [self.taskMap setObject:urlSchemeTask forKey:dataTask];
    [self.lock unlock];

    [dataTask resume];
}

/**
 * Inspects a raw XHR response's headers and captures the Alpha session cookie.  See the header
 * documentation for the Set-Cookie + X-A5WSessionId strategy.
 */
- (void)rememberCookiesFromResponseHeaders:(NSDictionary *)headerFields forURL:(NSURL *)url {
    if (![headerFields isKindOfClass:[NSDictionary class]] || url == nil) {
        return;
    }

    // Alpha sends the current session value on every response via X-A5WSessionId.
    NSString *sessionValue = [self headerValueForName:@"X-A5WSessionId" inHeaders:headerFields];

    // Parse any Set-Cookie header(s) generically (the session cookie name is configurable in Alpha,
    // so it is never hard-coded) and remember them.
    NSArray<NSHTTPCookie *> *responseCookies = [NSHTTPCookie cookiesWithResponseHeaderFields:headerFields forURL:url];
    BOOL sessionCookieInSetCookie = NO;
    if (responseCookies.count > 0) {
        [self rememberCookies:responseCookies];

        // Learn which cookie is the session cookie by matching its value to X-A5WSessionId.
        if (sessionValue.length > 0) {
            for (NSHTTPCookie *cookie in responseCookies) {
                if ([cookie.value isEqualToString:sessionValue]) {
                    [self.rememberedCookiesLock lock];
                    self.sessionCookieName = cookie.name;
                    self.sessionCookieDomain = cookie.domain;
                    self.sessionCookiePath = cookie.path.length > 0 ? cookie.path : @"/";
                    [self.rememberedCookiesLock unlock];
                    sessionCookieInSetCookie = YES;
                    if (self.diagnosticLoggingEnabled) {
                        NSLog(@"[AlphaSession] Learned session cookie name '%@' (domain %@) from Set-Cookie matching X-A5WSessionId.",
                              cookie.name, cookie.domain);
                    }
                    break;
                }
            }
        }
    }

    // If this response did not carry the session cookie in Set-Cookie but we already know the cookie
    // name, synthesise/refresh it from the always-present X-A5WSessionId value so the current session
    // id stays available to native session-file loads.
    if (sessionValue.length > 0 && !sessionCookieInSetCookie) {
        [self.rememberedCookiesLock lock];
        NSString *name = self.sessionCookieName;
        NSString *learnedDomain = self.sessionCookieDomain;
        NSString *learnedPath = self.sessionCookiePath;
        [self.rememberedCookiesLock unlock];

        if (name.length > 0) {
            NSString *domain = learnedDomain.length > 0 ? learnedDomain : url.host;
            NSString *path = learnedPath.length > 0 ? learnedPath : @"/";
            if (domain.length > 0) {
                NSDictionary *properties = @{
                    NSHTTPCookieName: name,
                    NSHTTPCookieValue: sessionValue,
                    NSHTTPCookieDomain: domain,
                    NSHTTPCookiePath: path,
                };
                NSHTTPCookie *sessionCookie = [NSHTTPCookie cookieWithProperties:properties];
                if (sessionCookie != nil) {
                    [self rememberCookies:@[ sessionCookie ]];
                    if (self.diagnosticLoggingEnabled) {
                        NSLog(@"[AlphaSession] Refreshed session cookie '%@' (domain %@) from X-A5WSessionId header.",
                              name, domain);
                    }
                }
            }
        }
    }
}

/**
 * Case-insensitive lookup of a single header value (response header dictionaries preserve the server's
 * original key casing).
 */
- (nullable NSString *)headerValueForName:(NSString *)name inHeaders:(NSDictionary *)headers {
    id direct = headers[name];
    if ([direct isKindOfClass:[NSString class]]) {
        return direct;
    }
    for (id key in headers) {
        if ([key isKindOfClass:[NSString class]] && [(NSString *)key caseInsensitiveCompare:name] == NSOrderedSame) {
            id value = headers[key];
            return [value isKindOfClass:[NSString class]] ? value : nil;
        }
    }
    return nil;
}

/**
 * Registers cookies observed on a raw XHR response so subsequent alpha-session requests can attach
 * them.  See the header documentation for why this is required for Partitioned session cookies.
 */
- (void)rememberCookies:(NSArray<NSHTTPCookie *> *)cookies {
    if (cookies.count == 0) {
        return;
    }
    [self.rememberedCookiesLock lock];
    for (NSHTTPCookie *cookie in cookies) {
        if (![cookie isKindOfClass:[NSHTTPCookie class]]) {
            continue;
        }
        NSString *key = [NSString stringWithFormat:@"%@\n%@\n%@",
                         cookie.name ?: @"", cookie.domain.lowercaseString ?: @"", cookie.path ?: @""];
        self.rememberedCookies[key] = cookie;
    }
    [self.rememberedCookiesLock unlock];

    if (self.diagnosticLoggingEnabled) {
        NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:cookies.count];
        for (NSHTTPCookie *cookie in cookies) {
            [names addObject:cookie.name ?: @""];
        }
        NSLog(@"[AlphaSession] Remembered %lu cookie(s) [%@] from XHR response.",
              (unsigned long)cookies.count, [names componentsJoinedByString:@", "]);
    }
}

/**
 * Returns a snapshot of the currently remembered cookies.
 */
- (NSArray<NSHTTPCookie *> *)rememberedCookiesSnapshot {
    [self.rememberedCookiesLock lock];
    NSArray<NSHTTPCookie *> *snapshot = [self.rememberedCookies.allValues copy];
    [self.rememberedCookiesLock unlock];
    return snapshot;
}

/**
 * Merges cookie collections from multiple labelled sources, de-duplicating by name/domain/path.
 * Earlier sources win over later ones when the same cookie appears in more than one.  Each entry is a
 * two-element array of the form @[ <NSArray of NSHTTPCookie>, <NSString label> ].  When diagnostics
 * are enabled, logs the source that supplied each cookie and any duplicates that were suppressed.
 */
- (NSArray<NSHTTPCookie *> *)mergeCookieSources:(NSArray<NSArray *> *)sources {
    NSMutableArray<NSHTTPCookie *> *merged = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *sourceForKey = [NSMutableDictionary dictionary];

    for (NSArray *entry in sources) {
        NSArray<NSHTTPCookie *> *source = entry[0];
        NSString *label = entry[1];
        for (NSHTTPCookie *cookie in source) {
            NSString *key = [NSString stringWithFormat:@"%@\n%@\n%@",
                             cookie.name ?: @"", cookie.domain.lowercaseString ?: @"", cookie.path ?: @""];
            NSString *existingSource = sourceForKey[key];
            if (existingSource != nil) {
                if (self.diagnosticLoggingEnabled) {
                    NSLog(@"[AlphaSession] Cookie '%@' (domain %@) also in %@; kept copy from %@ (priority).",
                          cookie.name, cookie.domain, label, existingSource);
                }
                continue;
            }
            sourceForKey[key] = label;
            [merged addObject:cookie];
            if (self.diagnosticLoggingEnabled) {
                NSLog(@"[AlphaSession] Cookie '%@' (domain %@) sourced from %@.",
                      cookie.name, cookie.domain, label);
            }
        }
    }
    return merged;
}

/**
 * Filters the supplied cookies down to those that apply to the given URL, honouring domain, path,
 * secure-only and expiry rules.  Mirrors the subset of RFC 6265 matching needed for session files.
 */
- (NSArray<NSHTTPCookie *> *)cookiesFrom:(NSArray<NSHTTPCookie *> *)cookies
                        applicableToURL:(NSURL *)url {
    NSString *host = url.host.lowercaseString;
    if (host.length == 0) {
        return @[];
    }
    NSString *path = url.path.length > 0 ? url.path : @"/";
    BOOL isSecureScheme = [url.scheme.lowercaseString isEqualToString:@"https"];
    NSDate *now = [NSDate date];

    NSMutableArray<NSHTTPCookie *> *result = [NSMutableArray array];
    for (NSHTTPCookie *cookie in cookies) {
        NSString *cookieDomain = cookie.domain.lowercaseString;
        BOOL domainMatches = NO;
        if ([cookieDomain hasPrefix:@"."]) {
            NSString *bareDomain = [cookieDomain substringFromIndex:1];
            domainMatches = [host isEqualToString:bareDomain] || [host hasSuffix:cookieDomain];
        } else {
            domainMatches = [host isEqualToString:cookieDomain];
        }
        if (!domainMatches) {
            continue;
        }

        NSString *cookiePath = cookie.path.length > 0 ? cookie.path : @"/";
        if (![path hasPrefix:cookiePath]) {
            continue;
        }

        if (cookie.isSecure && !isSecureScheme) {
            continue;
        }

        if (cookie.expiresDate != nil && [cookie.expiresDate compare:now] == NSOrderedAscending) {
            continue;
        }

        [result addObject:cookie];
    }
    return result;
}


- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask API_AVAILABLE(ios(11.0)) {
    NSURLSessionTask *taskToCancel = nil;

    [self.lock lock];
    // Remove from the active set first so any in-flight delegate callbacks are dropped.
    [self.activeSchemeTasks removeObject:urlSchemeTask];
    for (NSURLSessionTask *task in self.taskMap.keyEnumerator.allObjects) {
        if ([self.taskMap objectForKey:task] == urlSchemeTask) {
            taskToCancel = task;
            break;
        }
    }
    if (taskToCancel != nil) {
        [self.taskMap removeObjectForKey:taskToCancel];
    }
    [self.lock unlock];

    [taskToCancel cancel];
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {

    id<WKURLSchemeTask> schemeTask = [self schemeTaskForSessionTask:dataTask];
    if (schemeTask == nil || ![self isSchemeTaskActive:schemeTask]) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }

    if (self.diagnosticLoggingEnabled && [response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        BOOL hasSetCookie = httpResponse.allHeaderFields[@"Set-Cookie"] != nil;
        NSLog(@"[AlphaSession] Response %ld for %@ (Set-Cookie: %@)",
              (long)httpResponse.statusCode,
              response.URL.absoluteString,
              hasSetCookie ? @"yes" : @"no");
    }

    NSURLResponse *sanitized = [self sanitizedResponseForSchemeTask:schemeTask remoteResponse:response];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self isSchemeTaskActive:schemeTask]) {
            return;
        }
        @try {
            [schemeTask didReceiveResponse:sanitized];
        } @catch (NSException *exception) {
            NSLog(@"[AlphaSession] didReceiveResponse exception: %@", exception);
        }
    });

    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {

    id<WKURLSchemeTask> schemeTask = [self schemeTaskForSessionTask:dataTask];
    if (schemeTask == nil) {
        return;
    }

    NSData *chunk = [data copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self isSchemeTaskActive:schemeTask]) {
            return;
        }
        @try {
            [schemeTask didReceiveData:chunk];
        } @catch (NSException *exception) {
            NSLog(@"[AlphaSession] didReceiveData exception: %@", exception);
        }
    });
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(nullable NSError *)error {

    id<WKURLSchemeTask> schemeTask = [self schemeTaskForSessionTask:task];
    if (schemeTask == nil) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL wasActive = [self isSchemeTaskActive:schemeTask];
        [self finishTrackingSchemeTask:schemeTask sessionTask:task];

        if (!wasActive) {
            return;
        }
        if (self.diagnosticLoggingEnabled) {
            if (error != nil) {
                NSLog(@"[AlphaSession] Failed %@: %@", task.originalRequest.URL.absoluteString, error.localizedDescription);
            } else {
                NSLog(@"[AlphaSession] Completed %@", task.originalRequest.URL.absoluteString);
            }
        }
        @try {
            if (error != nil) {
                [schemeTask didFailWithError:error];
            } else {
                [schemeTask didFinish];
            }
        } @catch (NSException *exception) {
            NSLog(@"[AlphaSession] completion exception: %@", exception);
        }
    });
}

#pragma mark - Helpers

/**
 * Reconstructs the real http(s) URL from an alpha-session URL, validating the scheme and that the
 * request targets an Alpha session file.  Returns nil when the URL is not a valid session request.
 */
- (nullable NSURL *)reconstructTargetURLFromSchemeURL:(nullable NSURL *)schemeURL {
    NSString *absolute = schemeURL.absoluteString;
    if (absolute.length <= kAlphaSessionSchemePrefix.length) {
        return nil;
    }

    if ([[absolute substringToIndex:kAlphaSessionSchemePrefix.length] caseInsensitiveCompare:kAlphaSessionSchemePrefix] != NSOrderedSame) {
        return nil;
    }

    // e.g. "https/example.com/A5SessionFile/x.jpg?a=b#frag"
    NSString *remainder = [absolute substringFromIndex:kAlphaSessionSchemePrefix.length];

    NSRange firstSlash = [remainder rangeOfString:@"/"];
    if (firstSlash.location == NSNotFound || firstSlash.location == 0) {
        return nil;
    }

    NSString *protocol = [[remainder substringToIndex:firstSlash.location] lowercaseString];
    if (![protocol isEqualToString:@"http"] && ![protocol isEqualToString:@"https"]) {
        return nil;
    }

    NSString *rest = [remainder substringFromIndex:firstSlash.location + 1]; // "example.com/A5SessionFile/x.jpg?a=b#frag"
    if (rest.length == 0) {
        return nil;
    }

    // Require the session-file token in the path portion only (defense-in-depth against SSRF).
    NSString *pathPortion = rest;
    NSRange queryRange = [pathPortion rangeOfString:@"?"];
    if (queryRange.location != NSNotFound) {
        pathPortion = [pathPortion substringToIndex:queryRange.location];
    }
    NSRange fragmentRange = [pathPortion rangeOfString:@"#"];
    if (fragmentRange.location != NSNotFound) {
        pathPortion = [pathPortion substringToIndex:fragmentRange.location];
    }
    if ([pathPortion rangeOfString:kAlphaSessionRequiredPathToken].location == NSNotFound) {
        return nil;
    }

    NSString *targetURLString = [NSString stringWithFormat:@"%@://%@", protocol, rest];
    NSURL *targetURL = [NSURL URLWithString:targetURLString];
    if (targetURL == nil || targetURL.host.length == 0) {
        return nil;
    }

    return targetURL;
}

/**
 * Builds a response keyed to the original alpha-session request URL (rather than the remote https
 * URL) to avoid cross-origin confusion, while preserving the remote status code and headers so the
 * content type is available for rendering.
 */
- (NSURLResponse *)sanitizedResponseForSchemeTask:(id<WKURLSchemeTask>)schemeTask
                                   remoteResponse:(NSURLResponse *)remoteResponse API_AVAILABLE(ios(11.0)) {
    NSURL *responseURL = schemeTask.request.URL;

    if ([remoteResponse isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)remoteResponse;
        NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
        [httpResponse.allHeaderFields enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            if ([key isKindOfClass:[NSString class]] && [obj isKindOfClass:[NSString class]]) {
                headers[(NSString *)key] = (NSString *)obj;
            }
        }];

        NSHTTPURLResponse *sanitized = [[NSHTTPURLResponse alloc] initWithURL:responseURL
                                                                   statusCode:httpResponse.statusCode
                                                                  HTTPVersion:@"HTTP/1.1"
                                                                 headerFields:headers];
        if (sanitized != nil) {
            return sanitized;
        }
    }

    return [[NSURLResponse alloc] initWithURL:responseURL
                                     MIMEType:remoteResponse.MIMEType
                        expectedContentLength:remoteResponse.expectedContentLength
                             textEncodingName:remoteResponse.textEncodingName];
}

- (void)failSchemeTask:(id<WKURLSchemeTask>)schemeTask withError:(NSError *)error API_AVAILABLE(ios(11.0)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [schemeTask didFailWithError:error];
        } @catch (NSException *exception) {
            NSLog(@"[AlphaSession] failSchemeTask exception: %@", exception);
        }
    });
}

- (nullable id<WKURLSchemeTask>)schemeTaskForSessionTask:(NSURLSessionTask *)sessionTask API_AVAILABLE(ios(11.0)) {
    [self.lock lock];
    id<WKURLSchemeTask> schemeTask = [self.taskMap objectForKey:sessionTask];
    [self.lock unlock];
    return schemeTask;
}

- (BOOL)isSchemeTaskActive:(id<WKURLSchemeTask>)schemeTask API_AVAILABLE(ios(11.0)) {
    [self.lock lock];
    BOOL active = [self.activeSchemeTasks containsObject:schemeTask];
    [self.lock unlock];
    return active;
}

- (void)finishTrackingSchemeTask:(id<WKURLSchemeTask>)schemeTask
                     sessionTask:(NSURLSessionTask *)sessionTask API_AVAILABLE(ios(11.0)) {
    [self.lock lock];
    [self.activeSchemeTasks removeObject:schemeTask];
    if (sessionTask != nil) {
        [self.taskMap removeObjectForKey:sessionTask];
    }
    [self.lock unlock];
}

@end

NS_ASSUME_NONNULL_END

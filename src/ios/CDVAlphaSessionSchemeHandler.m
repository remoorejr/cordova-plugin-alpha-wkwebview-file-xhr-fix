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
            if ([configuration urlSchemeHandlerForURLScheme:kAlphaSessionScheme] == nil) {
                [configuration setURLSchemeHandler:[CDVAlphaSessionSchemeHandler sharedHandler]
                                      forURLScheme:kAlphaSessionScheme];
                NSLog(@"[AlphaSession] Attached alpha-session scheme handler to WKWebViewConfiguration.");
            }
        }
    }

    return configuration;
}

#pragma mark - WKURLSchemeHandler

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask API_AVAILABLE(ios(11.0)) {
    NSURLRequest *originalRequest = urlSchemeTask.request;
    NSURL *targetURL = [self reconstructTargetURLFromSchemeURL:originalRequest.URL];

    if (targetURL == nil) {
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain
                                             code:NSURLErrorUnsupportedURL
                                         userInfo:@{ NSLocalizedDescriptionKey: @"Invalid alpha-session URL." }];
        [self failSchemeTask:urlSchemeTask withError:error];
        return;
    }

    NSMutableURLRequest *proxyRequest = [NSMutableURLRequest requestWithURL:targetURL];
    proxyRequest.HTTPMethod = originalRequest.HTTPMethod.length > 0 ? originalRequest.HTTPMethod : @"GET";
    [proxyRequest setHTTPShouldHandleCookies:YES];

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

    NSURLSessionDataTask *dataTask = [self.urlSession dataTaskWithRequest:proxyRequest];

    [self.lock lock];
    [self.activeSchemeTasks addObject:urlSchemeTask];
    [self.taskMap setObject:urlSchemeTask forKey:dataTask];
    [self.lock unlock];

    [dataTask resume];
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

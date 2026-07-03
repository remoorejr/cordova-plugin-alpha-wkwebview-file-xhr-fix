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
 *
 * Adds a native "alpha-session" custom URL scheme handler for WKWebView.  This allows Alpha Anywhere
 * session files (e.g. /A5SessionFile/<guid>.jpg) referenced from an <img> element to be loaded with the
 * session cookie attached, which WKWebView does not do for native subresource loads.
 */

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * A shared WKURLSchemeHandler that services requests for the "alpha-session" scheme.
 *
 * The scheme is registered against the Cordova WKWebView configuration via a one-time method swizzle
 * installed in +load, because a custom scheme handler must be attached to the WKWebViewConfiguration
 * before the WKWebView is created (which happens inside the Cordova engine, before this plugin loads).
 *
 * Incoming URLs have the form produced by the Alpha helper:
 *   alpha-session://{protocol}/{host}{path}{search}{hash}
 * for example:
 *   alpha-session://https/example.com/A5SessionFile/b3a83799-d0d3-4ed8-b2b4-1d713758d3b7.jpg
 * which is reconstructed to:
 *   https://example.com/A5SessionFile/b3a83799-d0d3-4ed8-b2b4-1d713758d3b7.jpg
 */
API_AVAILABLE(ios(11.0))
@interface CDVAlphaSessionSchemeHandler : NSObject <WKURLSchemeHandler, NSURLSessionDataDelegate>

+ (instancetype)sharedHandler;

@end

NS_ASSUME_NONNULL_END

# Change Log

## cordova-plugin-alpha-wkwebview-file-xhr-fix v2.4.0 (07-03-2026)

- Added the `alpha-session` custom URL scheme handler ([CDVAlphaSessionSchemeHandler](src/ios/CDVAlphaSessionSchemeHandler.m)). It lets Alpha Anywhere session files (e.g. `/A5SessionFile/<guid>.jpg`) referenced from `<img>` elements load with the Alpha session cookie attached — something WKWebView does not do for native subresource loads. See the [README](README.md#alpha-anywhere-session-files-alpha-session-scheme) for details.
- Robust session-cookie handling for the `alpha-session` scheme. The session cookie is captured directly from the raw XHR response (`Set-Cookie`), the configurable cookie name is learned by matching against the always-present `X-A5WSessionId` response header, and cookies are sourced from the XHR response, the WebView `WKHTTPCookieStore`, and `NSHTTPCookieStorage` (in that priority). This works even for cross-site `HttpOnly; Secure; SameSite=None; Partitioned` (CHIPS) session cookies that are not reliably committed to the shared cookie store on the first response.
- Fixed a startup race condition in which the app could issue its first remote request before the XHR/`fetch` interception was installed (the polyfills previously loaded only as Cordova js-modules, which run late). The polyfills are now also injected as a document-start `WKUserScript` (all frames), so `XMLHttpRequest`/`fetch` are overridden before any app request runs. The js-modules remain as a self-guarded fallback.
- Added the `AlphaDiagnostics` config.xml preference (default off) to enable verbose `[AlphaSession]`/`[AlphaXHR]` native diagnostics without rebuilding the plugin source.

## cordova-plugin-alpha-wkwebview-file-xhr-fix v2.3.0 (11-16-2022)

- removed cordova-plugin-alpha-wkwebview dependency

## cordova-plugin-wkwebview-file-xhr v2.1.2 (TBD)

- allow funky characters in the URL (issue #25)

## cordova-plugin-wkwebview-file-xhr v2.1.1 (01/18/2018)

- XMLHttpRequest setRequestHeader normalizes the value pair to string types (issue #13).

## cordova-plugin-wkwebview-file-xhr v2.1.0 (12/1/2017)

- Added a FormData polyfill that works in tandem with the XMLHttpRequest polyfill (issue #4).
- Fixed compatibility issues with iOS 11 (issue #6).
- Rewired incorrect firing of the onerror event (issue #9).

## cordova-plugin-wkwebview-file-xhr v2.0.0 (9/20/2017)

- Introduced a new feature to intercept remote XHR requests bypassing wkwebivew's CORS handling.
- Bundled in the [whatwg-fetch](https://github.com/github/fetch) polyfill.
- Added several new configuration preferences - [README](README.md#configuration).

## cordova-plugin-wkwebview-file-xhr v1.0.0

- Bypassed wkwebview CORS handling of the XMLHttpRequest when loading file:// resources.

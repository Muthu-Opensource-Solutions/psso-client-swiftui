import SwiftUI
import WebKit
import os

/// Clean SwiftUI view embedding the OIDC login web view for Platform SSO user registration.
struct UserRegistrationView: View {
    let discoveryURL: URL
    let onResult: (Result<String, Error>) -> Void

    var body: some View {
        OIDCWebView(
            url: discoveryURL,
            onCallback: { encodedResult in
                onResult(.success(encodedResult))
            },
            onError: { error in
                onResult(.failure(error))
            }
        )
        .frame(minWidth: 900, minHeight: 700)
    }
}

// MARK: - OIDC WebView Representable
struct OIDCWebView: NSViewRepresentable {
    let url: URL
    let onCallback: (String) -> Void
    let onError: (Error) -> Void

    static let callbackPrefix = "psso-client-oidc-callback://result="

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        let request = URLRequest(url: url)
        AppLog.userRegistration.info("Loading OIDC discovery URL in WebView: \(url.absoluteString, privacy: .public)")
        webView.load(request)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    // MARK: - Coordinator
    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: OIDCWebView

        init(_ parent: OIDCWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            AppLog.network.error("OIDC WebView navigation failed: \(error.localizedDescription, privacy: .public)")
            parent.onError(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            // Ignore cancelled navigations triggered by callback redirection
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return
            }
            AppLog.network.error("OIDC WebView provisional navigation failed: \(error.localizedDescription, privacy: .public)")
            parent.onError(error)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let navigationURL = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let absoluteString = navigationURL.absoluteString
            AppLog.userRegistration.debug("OIDC WebView navigating to: \(absoluteString, privacy: .public)")

            if let range = absoluteString.range(of: OIDCWebView.callbackPrefix, options: [.caseInsensitive]) {
                decisionHandler(.cancel)
                AppLog.userRegistration.info("Intercepted OIDC callback redirect matching callback prefix")
                let token = String(absoluteString[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    if !token.isEmpty {
                        AppLog.userRegistration.info("Successfully extracted OIDC callback result token")
                        self.parent.onCallback(token)
                    } else {
                        AppLog.userRegistration.error("OIDC callback redirect contained an empty result token")
                        let err = NSError(
                            domain: "com.muthuopensource.psso-client-swiftui",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Missing 'result' token in OIDC callback redirect."]
                        )
                        self.parent.onError(err)
                    }
                }
                return
            }

            decisionHandler(.allow)
        }
    }
}

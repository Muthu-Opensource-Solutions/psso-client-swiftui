import SwiftUI
import WebKit
import os

/// Clean SwiftUI view embedding the OIDC login web view for Platform SSO user registration.
struct UserRegistrationView: View {
    let discoveryURL: URL
    let onResult: (Result<String, Error>) -> Void
    var onCancel: (() -> Void)? = nil

    // Common background color shared between header and footer
    private let barBackgroundColor = Color(red: 0.94, green: 0.94, blue: 0.96)

    var body: some View {
        VStack(spacing: 0) {
            // 1) Top Header Bar: Cancel button on left, centered "Sign In", background matching footer
            ZStack {
                HStack {
                    Button(action: {
                        onCancel?()
                    }) {
                        Text("Cancel")
                            .font(.system(size: 13, weight: .regular))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("Cancel Registration")

                    Spacer()
                }

                Text("Sign In")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(barBackgroundColor)
            .layoutPriority(2)

            Divider()
                .layoutPriority(2)

            // 2) Middle: Showing Web Page placed at center with black background, scrollable on all sides
            ZStack {
                Color.black

                OIDCWebView(
                    url: discoveryURL,
                    onCallback: { encodedResult in
                        onResult(.success(encodedResult))
                    },
                    onError: { error in
                        onResult(.failure(error))
                    }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .layoutPriority(0)

            Divider()
                .layoutPriority(2)

            // 3) Footer Bar: Centered text with lock icon, matching header background
            HStack(spacing: 8) {
                Spacer()
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(Color(red: 0.0, green: 0.47, blue: 1.0))
                    .font(.system(size: 13, weight: .semibold))
                Text("Sign in with this application to sync your password")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(red: 0.1, green: 0.1, blue: 0.1))
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(barBackgroundColor)
            .layoutPriority(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        // Accept whatever size the parent layout proposes so the WebView conforms
        // cleanly to the available space between header and footer
        guard let width = proposal.width, let height = proposal.height else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Use non-persistent website data store to prevent automatic login loop from cached session cookies
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()

        // Inject CSS and viewport configuration to ensure responsive behavior and scrolling on both axes
        let scrollCSS = """
        html, body {
            overflow: auto !important;
            -webkit-overflow-scrolling: touch;
            min-width: 100%;
            margin: 0;
            padding: 0;
        }
        """
        let scrollScript = """
        (function() {
            var style = document.createElement('style');
            style.type = 'text/css';
            style.appendChild(document.createTextNode('\(scrollCSS)'));
            (document.head || document.documentElement).appendChild(style);
        })();
        """
        let userScript = WKUserScript(source: scrollScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        configuration.userContentController.addUserScript(userScript)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.autoresizingMask = [.width, .height]

        // Enable scroll bars and elasticity
        if let scrollView = webView.enclosingScrollView {
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
        }

        // Make background transparent so dark background behind webview shows cleanly
        webView.setValue(false, forKey: "drawsBackground")

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

            if let token = extractCallbackToken(from: navigationURL) {
                decisionHandler(.cancel)
                AppLog.userRegistration.info("Intercepted OIDC callback redirect matching callback scheme")
                DispatchQueue.main.async {
                    AppLog.userRegistration.info("Successfully extracted OIDC callback result token")
                    self.parent.onCallback(token)
                }
                return
            }

            decisionHandler(.allow)
        }

        private func extractCallbackToken(from url: URL) -> String? {
            let absoluteString = url.absoluteString

            // Check case-insensitive prefix matching for psso-client-oidc-callback://result=
            if let range = absoluteString.range(of: OIDCWebView.callbackPrefix, options: [.caseInsensitive]) {
                let token = String(absoluteString[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty { return token }
            }

            // Fallback for custom scheme matching via URLComponents
            if url.scheme?.lowercased() == "psso-client-oidc-callback" {
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let item = components.queryItems?.first(where: { $0.name.lowercased() == "result" }),
                   let value = item.value, !value.isEmpty {
                    return value
                }
            }

            return nil
        }
    }
}

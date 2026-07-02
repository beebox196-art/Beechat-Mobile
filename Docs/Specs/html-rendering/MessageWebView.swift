// Reference scaffold — add to the iOS app target to use. iOS-only APIs throughout.
#if os(iOS)

import SwiftUI
import WebKit

/// Renders one message's **pre-sanitized** HTML at intrinsic height, for use inside a bubble:
///
///     MessageWebView(html: message.sanitizedHTML, height: $height)
///         .frame(height: height)
///         .padding(BeeChatTheme.bubblePadding)
///
/// Pairs with MessageTemplate.html (bundle resource "MessageTemplate").
/// Height flows: ResizeObserver (JS) → bcHeight message → async binding write → .frame.
struct MessageWebView: UIViewRepresentable {
    /// Sanitized upstream with a tag/attribute allowlist — never raw network input.
    let html: String
    @Binding var height: CGFloat
    var onLink: (URL) -> Void = { UIApplication.shared.open($0) }

    @Environment(\.colorScheme) private var colorScheme

    /// One pool app-wide: keeps all bubbles in a shared WebContent process arrangement.
    private static let processPool = WKProcessPool()

    private static let template: String = {
        guard let url = Bundle.main.url(forResource: "MessageTemplate", withExtension: "html"),
              let s = try? String(contentsOf: url) else {
            assertionFailure("MessageTemplate.html missing from bundle")
            return "<html><body><div id=\"content\"></div></body></html>"
        }
        return s
    }()

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        // Weak proxy: controller retains its handlers strongly; adding the coordinator
        // directly leaks a coordinator + web view per message.
        let proxy = WeakScriptMessageHandler(context.coordinator)
        ["bcHeight", "bcLink", "bcImage", "bcReady"].forEach { controller.add(proxy, name: $0) }

        let config = WKWebViewConfiguration()
        config.processPool = Self.processPool
        config.userContentController = controller
        config.dataDetectorTypes = []          // links come from the sanitizer, not detectors

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false               // no white flash in dark mode
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false      // bubble context menus stay native
        webView.loadHTMLString(Self.template, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        webView.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light

        // Cell reuse hands us a web view that showed a *different* message —
        // key on content identity, not "already loaded".
        if context.coordinator.currentHTML != html {
            context.coordinator.currentHTML = html
            context.coordinator.inject(into: webView)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        let controller = webView.configuration.userContentController
        ["bcHeight", "bcLink", "bcImage", "bcReady"].forEach {
            controller.removeScriptMessageHandler(forName: $0)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MessageWebView
        var currentHTML: String?
        private var templateReady = false

        init(_ parent: MessageWebView) { self.parent = parent }

        func inject(into webView: WKWebView) {
            guard templateReady, let html = currentHTML,
                  let data = try? JSONEncoder().encode(html),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.beechat.setContent(\(json))")
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            switch message.name {
            case "bcReady":
                templateReady = true
                if let webView = message.webView { inject(into: webView) }
            case "bcHeight":
                guard let h = message.body as? Double else { return }
                // Async hop: writing the binding synchronously here can land inside a
                // SwiftUI update pass ("Modifying state during view update").
                Task { @MainActor [parent] in parent.height = CGFloat(h) }
            case "bcLink":
                guard let raw = message.body as? String, let url = URL(string: raw),
                      ["http", "https", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "")
                else { return }
                Task { @MainActor [parent] in parent.onLink(url) }
            case "bcImage":
                break // hook up native full-screen viewer
            default:
                break
            }
        }

        // Deny everything except the initial template load; links already arrive via bcLink.
        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.navigationType == .other ? .allow : .cancel)
        }

        // Jetsam recovery: iOS killed our WebContent process; the bubble is blank.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            templateReady = false
            webView.loadHTMLString(MessageWebView.template, baseURL: nil)
        }
    }
}

/// Breaks the WKUserContentController → handler strong retain cycle.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

#endif

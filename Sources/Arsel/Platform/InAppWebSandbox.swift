#if canImport(UIKit)
import Foundation
import UIKit
import WebKit

/// A web view that draws author-supplied markup, and nothing else.
///
/// This is the only place the SDK renders content it did not construct, inside the CUSTOMER's own
/// app, so the hardening here is the feature — not the web view.
///
/// The markup reaches the SDK through a `WKScriptMessageHandler`, which carries only property-list
/// values: the page can describe an intent, but it can never name a Swift method, a selector or an
/// object. An inline creative is loaded with a **nil base URL**, which gives the page a unique
/// origin with no same-origin access to the app's files or to any http(s) host.
///
/// State is non-persistent. A marketing creative has no business leaving cookies or local storage
/// on the device, and storage shared between campaigns is a tracking surface the customer never
/// agreed to.
final class InAppWebSandbox: NSObject {
    let webView: WKWebView

    /// Receives each well-formed bridge message on the main queue. Only ever called when the
    /// author enabled JavaScript — a scriptless creative has nothing to say.
    private let onMessage: ([String: Any]) -> Void
    private let allowJavaScript: Bool

    /// Held directly rather than read back from `webView.configuration`, which returns a COPY —
    /// unregistering through that copy silently does nothing.
    private let contentController: WKUserContentController

    /// The sandbox performs exactly one top-level navigation: the creative itself.
    private var hasNavigated = false

    init(custom: InAppCustomHtml, onMessage: @escaping ([String: Any]) -> Void) {
        self.onMessage = onMessage
        self.allowJavaScript = custom.allowJavaScript
        self.contentController = WKUserContentController()

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = custom.allowJavaScript
        // Autoplaying video or audio out of a message the user never opened is hostile.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsInlineMediaPlayback = false

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.showsVerticalScrollIndicator = false
        // Bouncing reveals the app behind the message and reads as a rendering bug.
        webView.scrollView.bounces = false
        webView.navigationDelegate = self

        if custom.allowJavaScript {
            installBridge()
        }
        load(custom)
    }

    deinit {
        contentController.removeScriptMessageHandler(forName: Self.handlerName)
    }

    private func load(_ custom: InAppCustomHtml) {
        if custom.source == InAppHtmlSource.url,
           let raw = custom.url,
           let url = URL(string: raw) {
            webView.load(URLRequest(url: url))
            return
        }
        // A nil base URL is what makes the origin unique. Passing the app's own bundle URL here
        // would let the markup read the app's resources as same-origin.
        webView.loadHTMLString(custom.html ?? "", baseURL: nil)
    }

    private func installBridge() {
        contentController.addUserScript(
            WKUserScript(
                source: Self.bridgeShim,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true))
        // A weak proxy, because `WKUserContentController` retains its handlers strongly and this
        // object owns the controller — a cycle that never collects.
        contentController.add(WeakScriptMessageHandler(self), name: Self.handlerName)
    }

    /// Gives the markup the same API it has on the web.
    ///
    /// On the web the creative sits in an iframe and posts to `parent`. Here it is the top-level
    /// page, so `parent` is itself — this shim listens for exactly those posts and forwards them
    /// to the handler. One snippet therefore works unchanged on web, iOS and Android, which is the
    /// only way custom templates are portable at all.
    private static let bridgeShim = """
    (function () {
      if (window.__arselBridge) return;
      window.addEventListener('message', function (event) {
        var data = event.data;
        if (!data || typeof data.type !== 'string') return;
        if (data.type.lastIndexOf('arsel:', 0) !== 0) return;
        try {
          window.webkit.messageHandlers.arsel.postMessage(JSON.stringify(data));
        } catch (error) {}
      });
      window.__arselBridge = true;
    })();
    """

    static let handlerName = "arsel"
    private static let maxBridgeCharacters = 16_384
}

extension InAppWebSandbox: WKScriptMessageHandler {
    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard allowJavaScript, message.name == Self.handlerName else { return }
        // Bounded before it is parsed: the page is untrusted, and a multi-megabyte string would be
        // paid for on the main thread.
        guard let body = message.body as? String, body.count <= Self.maxBridgeCharacters else {
            return
        }
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        onMessage(json)
    }
}

extension InAppWebSandbox: WKNavigationDelegate {
    /// A tap inside the markup never navigates the sandbox.
    ///
    /// Letting it would turn the message into an uncontrolled browser inside the customer's app,
    /// with no address bar and no way back — and `location.href = …` would do it without a tap at
    /// all, which is why this allows exactly one top-level navigation rather than trusting the
    /// navigation type. An http(s) destination is handed to the system instead, where the user can
    /// see where they are; anything else is dropped.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // A sub-frame the creative declared itself is its own business; only the sandbox's own
        // top-level navigation is controlled here. A nil target frame means `_blank`, which falls
        // through to the external-open path below.
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
            return
        }
        if !hasNavigated {
            hasNavigated = true
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)

        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}

/// Breaks the `WKUserContentController` → handler retain cycle.
///
/// `add(_:name:)` keeps a strong reference for the controller's whole life, and the controller is
/// owned by the object registering itself — so a handler that is also its owner never deallocates.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(controller, didReceive: message)
    }
}
#endif

import SwiftUI
import WebKit

/// Container that owns the hosted WKWebView's frame (v0.4.10).
///
/// The sizing bug this fixes: up to v0.4.9 the representable returned
/// the bare, long-lived WKWebView and relied on SwiftUI's DEFAULT
/// representable sizing. That default derives the layout size from
/// the view's EXISTING frame whenever a measurement proposal is
/// unspecified — which happens inside the ZStack/VStack measurement
/// passes (the ZStack sizes to its largest child, and the web view
/// is that child, so the measurement is circular). The app also
/// writes web-view frames by hand (tab previews, the SNAP full-page
/// grow/restore), so once a stale, larger-than-window frame got in —
/// a preview resize at a previous window size, a SNAP restore, a
/// background tab resized while the window was bigger — SwiftUI's
/// measurement adopted the stale size and fed it back as the
/// proposal. The page's layout viewport stayed wider than the
/// visible window and live window resizes never converged it.
///
/// Now the web view's frame is a pure function of the rect SwiftUI
/// actually allocates: this container fills that rect, and its
/// layoutSubviews forces the web view to fill the container on every
/// layout pass — window drag-resizes included, no reload needed.
final class WebViewContainerView: UIView {
    private(set) var webView: WKWebView?

    func attach(_ webView: WKWebView) {
        if self.webView === webView { return }
        detach()
        self.webView = webView
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.frame = bounds
        addSubview(webView)
    }

    func detach() {
        webView?.removeFromSuperview()
        webView = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let webView, webView.frame != bounds {
            webView.frame = bounds
        }
    }
}

/// SwiftUI wrapper: the WKWebView itself is owned by BrowserModel so the
/// SNAP code and the UI always talk to the same instance.
struct WebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WebViewContainerView {
        let container = WebViewContainerView()
        container.attach(webView)
        return container
    }

    func updateUIView(_ container: WebViewContainerView, context: Context) {
        // Tab switches hand us a different WKWebView; navigation is
        // driven imperatively through BrowserModel.
        if container.webView !== webView {
            container.attach(webView)
        }
    }

    static func dismantleUIView(_ container: WebViewContainerView, coordinator: ()) {
        container.detach()
    }

    /// Report the proposed size verbatim. The default implementation
    /// falls back to the view's current frame for unspecified
    /// dimensions, which is exactly how a stale oversized frame used
    /// to leak into the layout (see WebViewContainerView).
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: WebViewContainerView,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.bounds.width,
               height: proposal.height ?? uiView.bounds.height)
    }
}

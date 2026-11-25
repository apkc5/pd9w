import SwiftUI
import WebKit

/// Thin SwiftUI wrapper: the WKWebView itself is owned by BrowserModel so the
/// SNAP code and the UI always talk to the same instance.
struct WebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Navigation is driven imperatively through BrowserModel.
    }
}

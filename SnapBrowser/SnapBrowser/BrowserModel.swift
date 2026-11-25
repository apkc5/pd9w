import Foundation
import WebKit
import UIKit

/// Owns the single WKWebView for the browser tab and all SNAP capture logic.
///
/// Persistence rule for this app: files + UserDefaults only.
/// No Keychain anywhere (AltStore re-signing breaks Keychain access —
/// that is what kept logging the user out of another sideloaded app).
@MainActor
final class BrowserModel: ObservableObject {
    let webView: WKWebView

    @Published var addressText: String = ""
    @Published var pageTitle: String = ""
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isLoading: Bool = false
    @Published var estimatedProgress: Double = 0

    @Published var isSnapping: Bool = false
    @Published var lastSnapResult: SnapResult?

    private var observations: [NSKeyValueObservation] = []

    static let homeURL = URL(string: "https://example.com")!
    private static let lastURLKey = "lastURL"

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // iOS equivalent of Android's "desktop site" plumbing is left out of v0.1.
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

        observations.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.canGoBack = wv.canGoBack }
        })
        observations.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.canGoForward = wv.canGoForward }
        })
        observations.append(webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.isLoading = wv.isLoading }
        })
        observations.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.estimatedProgress = wv.estimatedProgress }
        })
        observations.append(webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.pageTitle = wv.title ?? "" }
        })
        observations.append(webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in
                guard let self else { return }
                if let url = wv.url {
                    self.addressText = url.absoluteString
                    UserDefaults.standard.set(url.absoluteString, forKey: Self.lastURLKey)
                }
            }
        })

        let start = UserDefaults.standard.string(forKey: Self.lastURLKey)
            .flatMap(URL.init(string:)) ?? Self.homeURL
        load(start)
    }

    // MARK: - Navigation

    func loadAddressBar() {
        let text = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let url = Self.urlFromAddressText(text) {
            load(url)
        }
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    /// Accepts full URLs, bare domains, and plain search terms (Brave Search,
    /// matching the Android version's default engine).
    static func urlFromAddressText(_ text: String) -> URL? {
        if let url = URL(string: text), url.scheme == "http" || url.scheme == "https" {
            return url
        }
        let looksLikeDomain = text.contains(".") && !text.contains(" ")
        if looksLikeDomain, let url = URL(string: "https://" + text) {
            return url
        }
        var components = URLComponents(string: "https://search.brave.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        return components?.url
    }

    // MARK: - SNAP

    struct SnapResult {
        var title: String
        var url: String
        var imageBytes: Int?
        var archiveBytes: Int?
        var textChars: Int?
        var htmlBytes: Int?
        var failures: [String]
    }

    /// One-tap snapshot, mirroring the Android 3-piece set:
    /// full-page PNG + .webarchive (iOS's archive format) + body text,
    /// plus the raw HTML source (the portable piece — .webarchive is Apple-only).
    /// A component counts as saved only when its file actually exists on disk.
    func snap(store: SnapshotStore) {
        guard !isSnapping else { return }
        isSnapping = true
        lastSnapResult = nil

        Task {
            var failures: [String] = []
            let sourceURL = webView.url ?? Self.homeURL
            let title = webView.title ?? sourceURL.host ?? "ページ"

            // 1) Full-page image (frame-resize capture; falls back to viewport).
            var imageData: Data?
            do {
                let image = try await captureFullPageImage()
                imageData = image.pngData()
                if imageData == nil { failures.append("画像のPNG変換に失敗") }
            } catch {
                failures.append("画像: \(error.localizedDescription)")
            }

            // 2) Web archive (.webarchive, iOS 14+).
            var archiveData: Data?
            do {
                archiveData = try await webView.createWebArchiveData()
            } catch {
                failures.append("アーカイブ: \(error.localizedDescription)")
            }

            // 3) Body text via JS.
            var text: String?
            do {
                let raw = try await webView.evaluateJavaScript("document.body ? document.body.innerText : ''")
                text = raw as? String
                if text == nil { failures.append("テキスト: 取得結果が文字列でない") }
            } catch {
                failures.append("テキスト: \(error.localizedDescription)")
            }

            // 4) Raw HTML via JS (portable archive companion).
            var htmlData: Data?
            do {
                let raw = try await webView.evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML : ''")
                if let html = raw as? String {
                    htmlData = Data(html.utf8)
                }
            } catch {
                failures.append("HTML: \(error.localizedDescription)")
            }

            var result = SnapResult(title: title,
                                    url: sourceURL.absoluteString,
                                    imageBytes: nil, archiveBytes: nil,
                                    textChars: nil, htmlBytes: nil,
                                    failures: failures)
            do {
                let saved = try store.save(title: title,
                                           url: sourceURL.absoluteString,
                                           imageData: imageData,
                                           archiveData: archiveData,
                                           text: text,
                                           htmlData: htmlData)
                result.imageBytes = saved.imageBytes
                result.archiveBytes = saved.archiveBytes
                result.textChars = saved.textChars
                result.htmlBytes = saved.htmlBytes
                result.failures.append(contentsOf: saved.failures)
            } catch {
                result.failures.append("保存: \(error.localizedDescription)")
            }

            lastSnapResult = result
            isSnapping = false
        }
    }

    /// Full-page capture by temporarily growing the web view to the page's
    /// content height, then snapshotting the whole frame.
    ///
    /// Caveats (also in FEASIBILITY.md): WKWebView's takeSnapshot only ever
    /// captures a rect of the view, so pages taller than the cap below are
    /// captured at reduced fidelity/fail over to the visible viewport.
    /// Extremely long pages can also hit memory limits while the layer grows.
    private func captureFullPageImage() async throws -> UIImage {
        let webView = self.webView
        let scrollView = webView.scrollView

        let contentHeight = scrollView.contentSize.height
        let viewportHeight = webView.bounds.height
        let maxHeight: CGFloat = 16_000

        guard contentHeight > viewportHeight + 1, contentHeight <= maxHeight else {
            // Short page (or absurdly long): visible-area snapshot is the honest result.
            return try await snapshotCurrentView()
        }

        let originalFrame = webView.frame
        let originalOffset = scrollView.contentOffset
        let originalSuperview = webView.superview

        // Detach into a full-height frame offscreen, let it lay out, snapshot, restore.
        webView.frame = CGRect(x: 0, y: 0,
                               width: originalFrame.width,
                               height: contentHeight)
        scrollView.contentOffset = .zero
        webView.setNeedsLayout()
        webView.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 350_000_000)

        do {
            let config = WKSnapshotConfiguration()
            config.rect = webView.bounds
            let image = try await webView.takeSnapshot(configuration: config)
            webView.frame = originalFrame
            _ = originalSuperview // frame restore is enough while attached; superview never changed
            scrollView.contentOffset = originalOffset
            return image
        } catch {
            webView.frame = originalFrame
            scrollView.contentOffset = originalOffset
            // Fall back to whatever is on screen rather than failing the whole snap.
            return try await snapshotCurrentView()
        }
    }

    private func snapshotCurrentView() async throws -> UIImage {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        return try await webView.takeSnapshot(configuration: config)
    }
}

import Foundation
import WebKit
import UIKit

/// One browser tab: owns its WKWebView for the whole session (never
/// destroyed on tab switch, like the Android version), plus its published
/// UI state, its start-page state, its archive state and its SNAP logic.
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let webView: WKWebView

    @Published var addressText: String = ""
    @Published var pageTitle: String = ""
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isLoading: Bool = false
    @Published var estimatedProgress: Double = 0
    @Published var showsStartPage: Bool = true
    @Published var previewImage: UIImage?

    /// Set while this tab displays a saved snapshot instead of the live page.
    @Published var archiveSnapshot: SnapshotItem?
    private(set) var archiveFileURL: URL?
    /// Kept after leaving an archive so back-navigation can restore it.
    private var recentArchive: (item: SnapshotItem, fileURL: URL)?
    /// Folder name of an archive tab restored from a previous session;
    /// ContentView resolves it against the SnapshotStore on appear.
    var pendingArchiveFolderName: String?

    @Published var isSnapping: Bool = false
    @Published var lastSnapResult: SnapResult?

    /// Called on every finished live navigation (title, url) — history hook.
    var onVisit: ((String, String) -> Void)?

    private var observations: [NSKeyValueObservation] = []

    init(startURL: URL?) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: UIScreen.main.bounds, configuration: config)
        super.init()
        webView.navigationDelegate = self
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
                guard let self, let url = wv.url else { return }
                if self.archiveSnapshot != nil, url.isFileURL {
                    // Address bar keeps showing the original page URL.
                    self.addressText = self.archiveSnapshot?.url ?? url.absoluteString
                } else {
                    self.addressText = url.absoluteString
                }
            }
        })

        if let startURL {
            load(startURL)
        }
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
        clearArchive()
        showsStartPage = false
        webView.load(URLRequest(url: url))
    }

    func showStartPage() {
        clearArchive()
        showsStartPage = true
        addressText = ""
        pageTitle = ""
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stop() { webView.stopLoading() }

    var currentURLString: String? {
        if let archiveSnapshot { return archiveSnapshot.url }
        return webView.url?.absoluteString
    }

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

    // MARK: - Archive display

    /// Opens a saved snapshot inside this tab as if it were the page itself:
    /// the address bar shows the original URL and the 保存版 banner appears.
    func openArchive(item: SnapshotItem, store: SnapshotStore) {
        let folder = store.folderURL(for: item)
        let fm = FileManager.default
        let file = ["full.html", "page.html", "archive.webarchive"]
            .map { folder.appendingPathComponent($0) }
            .first { fm.fileExists(atPath: $0.path) }
        guard let file else { return }
        archiveSnapshot = item
        archiveFileURL = file
        recentArchive = (item, file)
        pendingArchiveFolderName = nil
        showsStartPage = false
        addressText = item.url
        pageTitle = item.title
        webView.loadFileURL(file, allowingReadAccessTo: folder)
    }

    private func clearArchive() {
        if let archiveSnapshot, let archiveFileURL {
            recentArchive = (archiveSnapshot, archiveFileURL)
        }
        archiveSnapshot = nil
        archiveFileURL = nil
    }

    /// Runs a javascript: bookmarklet in the current page context
    /// (standard bookmarklet behaviour, same as Android).
    func runBookmarklet(_ urlString: String) {
        guard urlString.lowercased().hasPrefix("javascript:") else { return }
        let code = String(urlString.dropFirst("javascript:".count))
            .removingPercentEncoding ?? String(urlString.dropFirst("javascript:".count))
        guard !showsStartPage, archiveSnapshot == nil else { return }
        Task {
            _ = try? await webView.evaluateJavaScript(code)
        }
    }

    // MARK: - Preview (tab overview thumbnails)

    func capturePreview() {
        guard !showsStartPage, webView.bounds.width > 0 else { return }
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            guard let image else { return }
            Task { @MainActor in self?.previewImage = image }
        }
    }

    // MARK: - SNAP

    struct SnapResult {
        var title: String
        var url: String
        var imageBytes: Int?
        var archiveBytes: Int?
        var textChars: Int?
        var htmlBytes: Int?
        var fullHTMLBytes: Int?
        var assetsInlined: String?
        var failures: [String]
    }

    /// One-tap snapshot: full-page PNG + .webarchive + body text + raw HTML,
    /// plus the self-contained HTML used for in-tab archive viewing.
    /// A component counts as saved only when its file actually exists.
    func snap(store: SnapshotStore) {
        guard !isSnapping, !showsStartPage, archiveSnapshot == nil else { return }
        isSnapping = true
        lastSnapResult = nil

        Task {
            var failures: [String] = []
            let sourceURL = webView.url ?? URL(string: "https://example.com")!
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

            // 2) Web archive (.webarchive, iOS 14+). This API has NO async
            // variant in the SDK — bridged via continuation (see helpers).
            var archiveData: Data?
            do {
                archiveData = try await Self.createWebArchiveData(from: webView)
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

            // 5) Self-contained HTML (styles/images inlined for offline view).
            var fullHTMLData: Data?
            var assetsNote: String?
            do {
                let built = try await SelfContainedHTML.build(from: webView)
                fullHTMLData = built.data
                assetsNote = "\(built.inlined)/\(built.total)"
            } catch {
                failures.append("自己完結HTML: \(error.localizedDescription)")
            }

            var result = SnapResult(title: title,
                                    url: sourceURL.absoluteString,
                                    imageBytes: nil, archiveBytes: nil,
                                    textChars: nil, htmlBytes: nil,
                                    fullHTMLBytes: nil, assetsInlined: assetsNote,
                                    failures: failures)
            do {
                let saved = try store.save(title: title,
                                           url: sourceURL.absoluteString,
                                           imageData: imageData,
                                           archiveData: archiveData,
                                           text: text,
                                           htmlData: htmlData,
                                           fullHTMLData: fullHTMLData)
                result.imageBytes = saved.imageBytes
                result.archiveBytes = saved.archiveBytes
                result.textChars = saved.textChars
                result.htmlBytes = saved.htmlBytes
                result.fullHTMLBytes = saved.fullHTMLBytes
                result.failures.append(contentsOf: saved.failures)
            } catch {
                result.failures.append("保存: \(error.localizedDescription)")
            }

            lastSnapResult = result
            isSnapping = false
        }
    }

    /// Full-page capture by temporarily growing the web view to the page's
    /// content height, then snapshotting the whole frame. Pages taller than
    /// the cap fall back to the visible viewport (honest limitation).
    private func captureFullPageImage() async throws -> UIImage {
        let webView = self.webView
        let scrollView = webView.scrollView

        let contentHeight = scrollView.contentSize.height
        let viewportHeight = webView.bounds.height
        let maxHeight: CGFloat = 16_000

        guard contentHeight > viewportHeight + 1, contentHeight <= maxHeight else {
            return try await snapshotCurrentView()
        }

        let originalFrame = webView.frame
        let originalOffset = scrollView.contentOffset

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
            let image = try await Self.takeSnapshot(of: webView, configuration: config)
            webView.frame = originalFrame
            scrollView.contentOffset = originalOffset
            return image
        } catch {
            webView.frame = originalFrame
            scrollView.contentOffset = originalOffset
            return try await snapshotCurrentView()
        }
    }

    private func snapshotCurrentView() async throws -> UIImage {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        return try await Self.takeSnapshot(of: webView, configuration: config)
    }

    // MARK: - WebKit completion-handler bridges
    // Neither of these APIs gets an importer-generated async variant in the
    // current SDK, so wrap the completion handlers explicitly.

    private static func createWebArchiveData(from webView: WKWebView) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            webView.createWebArchiveData { result in
                switch result {
                case .success(let data):
                    continuation.resume(returning: data)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func takeSnapshot(of webView: WKWebView,
                                     configuration: WKSnapshotConfiguration) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? NSError(
                        domain: "SnapBrowser", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "スナップショット撮影に失敗"]))
                }
            }
        }
    }
}

// MARK: - WKNavigationDelegate (archive state + history)

extension BrowserTab: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView,
                             didStartProvisionalNavigation navigation: WKNavigation!) {
        let url = webView.url
        Task { @MainActor in
            guard let url else { return }
            if url.isFileURL {
                // Returning to a saved archive via back/forward restores it.
                if let recent = self.recentArchive, url == recent.fileURL {
                    self.archiveSnapshot = recent.item
                    self.archiveFileURL = recent.fileURL
                    self.addressText = recent.item.url
                }
            } else if url.scheme == "http" || url.scheme == "https" {
                // Following a link out of an archive → live page, banner off.
                if self.archiveSnapshot != nil {
                    self.clearArchive()
                }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFinish navigation: WKNavigation!) {
        let url = webView.url
        let title = webView.title
        Task { @MainActor in
            self.capturePreview()
            guard let url, url.scheme == "http" || url.scheme == "https",
                  self.archiveSnapshot == nil, !self.showsStartPage else { return }
            self.onVisit?(title ?? url.host ?? url.absoluteString, url.absoluteString)
        }
    }
}

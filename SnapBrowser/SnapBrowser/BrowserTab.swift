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

    /// Shared user preferences (search engine / desktop default / zoom).
    let settings: AppSettings
    /// Private tabs use a non-persistent data store, record no history
    /// and are never written into the saved session (v0.4).
    let isPrivate: Bool
    /// Desktop-site mode for this tab (desktop UA), toggled from the menu.
    @Published var desktopMode: Bool

    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

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

    init(startURL: URL?, settings: AppSettings, isPrivate: Bool = false) {
        self.settings = settings
        self.isPrivate = isPrivate
        self.desktopMode = settings.desktopByDefault
        let config = WKWebViewConfiguration()
        config.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        // Frame starts at .zero: SwiftUI sizes the web view to the real
        // window. (v0.3 and earlier used UIScreen.main.bounds, which is
        // the full iPad screen even in a small floating window — that
        // mismatch is what distorted tab previews there.)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if desktopMode {
            webView.customUserAgent = Self.desktopUserAgent
        }
        webView.pageZoom = CGFloat(settings.textSizePercent) / 100.0

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
        if let url = urlFromAddressText(text) {
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

    /// Accepts full URLs, bare domains, and plain search terms (resolved
    /// with the user's chosen search engine; Brave Search by default).
    func urlFromAddressText(_ text: String) -> URL? {
        if let url = URL(string: text), url.scheme == "http" || url.scheme == "https" {
            return url
        }
        let looksLikeDomain = text.contains(".") && !text.contains(" ")
        if looksLikeDomain, let url = URL(string: "https://" + text) {
            return url
        }
        return settings.searchEngine.searchURL(for: text)
    }

    // MARK: - Desktop site / text size (v0.4)

    /// Switches this tab between mobile and desktop user agents and
    /// reloads so the site serves the matching layout.
    func setDesktopMode(_ on: Bool) {
        guard on != desktopMode else { return }
        desktopMode = on
        webView.customUserAgent = on ? Self.desktopUserAgent : nil
        if !showsStartPage, archiveSnapshot == nil {
            reload()
        }
    }

    /// Re-applies the settings text size (page zoom) to this tab.
    func applyTextSize() {
        webView.pageZoom = CGFloat(settings.textSizePercent) / 100.0
    }

    // MARK: - Find in page (v0.4)

    /// Native WKWebView find: highlights and scrolls to the match.
    func findInPage(_ query: String, backwards: Bool,
                    completion: @escaping (Bool) -> Void) {
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        webView.find(query, configuration: config) { result in
            completion(result.matchFound)
        }
    }

    /// Approximate total match count from the page's visible text
    /// (WKWebView.find itself reports only whether a match exists).
    func countMatches(of query: String) async -> Int {
        guard !query.isEmpty else { return 0 }
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = "(function(){var t=(document.body&&document.body.innerText)||'';"
            + "var q='\(escaped)'.toLowerCase();if(!q)return 0;"
            + "return t.toLowerCase().split(q).length-1;})()"
        guard let raw = try? await webView.evaluateJavaScript(js) else { return 0 }
        if let number = raw as? NSNumber { return number.intValue }
        return 0
    }

    // MARK: - Reader extraction (v0.4)

    /// Heuristic article extraction for reader mode: picks the main /
    /// article element, or the text-densest block, clones it, strips
    /// scripts, chrome and ALL attributes except img src/alt and link
    /// hrefs (made absolute, javascript: dropped), and returns JSON.
    func extractReaderContent() async -> (title: String, bodyHTML: String)? {
        guard let raw = try? await webView.evaluateJavaScript(Self.readerExtractionJS),
              let json = raw as? String,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = object["html"] as? String else { return nil }
        return (object["title"] as? String ?? "", body)
    }

    private static let readerExtractionJS = """
    (function () {
      var title = document.title || '';
      function abs(u) { try { return new URL(u, document.baseURI).href; } catch (e) { return ''; } }
      function textLen(el) { return ((el && el.innerText) || '').trim().length; }
      var root = document.querySelector('main') || document.querySelector('article');
      if (!root) {
        var best = null, bestScore = 0;
        var nodes = document.querySelectorAll('div, section, td');
        for (var i = 0; i < nodes.length; i++) {
          var el = nodes[i];
          var t = textLen(el);
          if (t < 200) continue;
          var links = el.querySelectorAll('a');
          var linkText = 0;
          for (var j = 0; j < links.length; j++) linkText += (links[j].innerText || '').length;
          var score = t - linkText * 2;
          if (score > bestScore) { bestScore = score; best = el; }
        }
        root = best || document.body;
      }
      if (!root) return JSON.stringify({ title: title, html: '' });
      var clone = root.cloneNode(true);
      var kill = clone.querySelectorAll('script, style, nav, header, footer, aside, form, iframe, noscript, button, svg');
      for (var k = 0; k < kill.length; k++) kill[k].remove();
      function clean(node) {
        var keep = {};
        if (node.tagName === 'A') {
          var href = node.getAttribute('href');
          var resolved = href ? abs(href) : '';
          if (resolved && resolved.toLowerCase().indexOf('javascript:') !== 0) keep.href = resolved;
        }
        if (node.tagName === 'IMG') {
          var src = node.getAttribute('src') || node.getAttribute('data-src');
          var rsrc = src ? abs(src) : '';
          if (rsrc) keep.src = rsrc;
          if (node.getAttribute('alt')) keep.alt = node.getAttribute('alt');
        }
        var attrs = Array.prototype.slice.call(node.attributes || []);
        for (var a = 0; a < attrs.length; a++) node.removeAttribute(attrs[a].name);
        for (var key in keep) node.setAttribute(key, keep[key]);
      }
      clean(clone);
      var all = clone.querySelectorAll('*');
      for (var m = 0; m < all.length; m++) clean(all[m]);
      return JSON.stringify({ title: title, html: clone.innerHTML || '' });
    })()
    """

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
        capturePreview(matching: webView.bounds.size)
    }

    /// Captures the tab preview at the given size. Background tabs are
    /// not in the view hierarchy, so without this their web views keep
    /// whatever frame they were created with and the snapshot's aspect
    /// (and the page layout inside it) does not match the window the
    /// user is actually looking at — the distortion reported on iPad
    /// floating windows in v0.3. The manager passes the active tab's
    /// real bounds so every preview matches the current window.
    func capturePreview(matching size: CGSize) {
        guard !showsStartPage else { return }
        var resized = false
        if size.width > 0, webView.bounds.size != size {
            webView.frame = CGRect(origin: .zero, size: size)
            resized = true
        }
        guard webView.bounds.width > 0 else { return }
        if resized {
            // Let the page lay out at the new size before snapshotting.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 80_000_000)
                self?.performPreviewCapture()
            }
        } else {
            performPreviewCapture()
        }
    }

    private func performPreviewCapture() {
        guard webView.bounds.width > 0 else { return }
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

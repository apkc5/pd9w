import Foundation
import WebKit
import UIKit
import Photos

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

    /// Media detected on the current page (v0.4.6): drives the
    /// toolbar save badge and the ⋯ menu's Playlist add. Refreshed
    /// after each navigation finishes, once more ~3s later for
    /// lazily-loaded videos, and on light DOM-change notifications
    /// from the probe script (event-driven, no polling).
    @Published var detectedMedia: [DetectedMedia] = []
    /// A video long-press resolved to a saveable URL: ContentView
    /// shows the add confirmation while this is non-nil. Feedback is
    /// guaranteed — unresolvable presses land in mediaNotice instead.
    @Published var pendingLongPress: DetectedMedia?
    /// Honest dead-end notice for a long-pressed video (blob: / no
    /// resolvable URL), shown as an alert by ContentView.
    @Published var mediaNotice: String?

    private var delayedProbeTask: Task<Void, Never>?
    private var lastProbeRefresh: Date = .distantPast

    static let mediaMessageName = "snapMedia"
    /// blob: download bridge (v0.4.10) — see blobDownloadScript.
    static let blobMessageName = "snapBlob"

    /// The model's download store, wired in makeTab. Used directly
    /// (not via downloadHandler) for blob: downloads, which arrive
    /// as streamed chunks from the page rather than as a WKDownload.
    var downloadStore: DownloadStore?
    /// In-flight blob transfers: bridge id → download item id.
    private var blobTransfers: [String: UUID] = [:]

    /// The model's playlist store, wired in makeTab (v0.4.14):
    /// plain Blobs classified in the page are streamed into it,
    /// and its downloads borrow this tab's cookies / UA.
    var playlistStore: PlaylistStore?
    /// Blob→Playlist transfers in flight: transfer id → the
    /// context captured when the save was initiated.
    private var playlistBlobContext: [String: (title: String, pageURL: String?)] = [:]
    /// Blob→Playlist transfers: transfer id → playlist item id.
    private var playlistBlobItems: [String: UUID] = [:]
    /// A long-pressed blob that classified as a plain Blob (A):
    /// the add confirmation is showing, and confirming starts the
    /// transfer from the frame that generated the blob.
    private var pendingBlobSave: (url: String, frame: WKFrameInfo?, title: String)?

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

    // MARK: - Delegate plumbing (v0.4.9)
    //
    // Until v0.4.8 the web view had NO uiDelegate: JavaScript
    // alert/confirm/prompt were silently swallowed, window.open /
    // target=_blank links did nothing at all, and there was no
    // context menu, no download conversion and no error surface.
    // The state below is what ContentView renders for those flows.

    /// A pending JavaScript panel (alert / confirm / prompt).
    @Published var jsPanel: JSPanelRequest?
    /// A pending HTTP Basic/Digest authentication challenge.
    @Published var authRequest: AuthRequest?
    /// Last main-frame load failure, shown as an error card with a
    /// reload button instead of a blank page. Cleared on the next
    /// successful navigation.
    @Published var loadError: String?
    /// One-shot notice for flows that end outside the page
    /// (external-scheme hand-off failures, image saves).
    @Published var tabNotice: String?

    /// Name of the document this tab is currently DISPLAYING inline
    /// (v0.4.10) — a PDF or similar file the web view rendered
    /// instead of downloading. Non-nil is what makes the ⋯ menu's
    /// 「このファイルをダウンロード」 appear: until v0.4.9 a PDF
    /// link simply opened inline (canShowMIMEType is true for PDFs,
    /// so the response policy allowed it) and there was NO way to
    /// save the file at all — the user's 「ダウンロードできない」.
    /// Since v0.4.13 media files the web view plays inline (a
    /// direct .mp4/.mp3) count too, so a playing video can be
    /// saved through the same menu row.
    @Published var currentDocumentName: String?
    /// URL of that inline document, for the re-download request.
    private var currentDocumentURL: URL?

    /// window.open / target=_blank / context-menu "open in new tab".
    var onOpenInNewTab: ((URL) -> Void)?
    /// A navigation that turned into a download (WKDownload).
    var downloadHandler: ((WKDownload) -> Void)?
    /// Context-menu share (items for UIActivityViewController).
    var shareHandler: (([Any]) -> Void)?
    /// Context-menu "このページをスナップ".
    var snapHandler: (() -> Void)?
    /// Context-menu "Playlistに追加" for media links.
    var playlistLinkHandler: ((String) -> Void)?

    /// The link / image under the most recent touch, reported by the
    /// probe script. WKContextMenuElementInfo exposes linkURL but
    /// no image URL, so image context menus resolve through this.
    private var lastTouchLink: String?
    private var lastTouchImage: String?
    private var lastTouchAt: Date = .distantPast

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
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if desktopMode {
            webView.customUserAgent = Self.desktopUserAgent
        }
        webView.pageZoom = CGFloat(settings.textSizePercent) / 100.0

        // Media probe (v0.4.6): one user script in every frame —
        // video long-press detection plus a debounced DOM-change
        // ping — reporting back through the snapMedia handler.
        // Registered before the initial load below so the start page
        // load is covered too.
        let userContent = webView.configuration.userContentController
        userContent.addUserScript(WKUserScript(source: Self.mediaProbeScript,
                                               injectionTime: .atDocumentEnd,
                                               forMainFrameOnly: false))
        userContent.add(self, name: Self.mediaMessageName)
        // blob: download bridge (v0.4.10): at document start, main
        // frame only — see the script's comment for why.
        userContent.addUserScript(WKUserScript(source: Self.blobDownloadScript,
                                               injectionTime: .atDocumentStart,
                                               forMainFrameOnly: true))
        userContent.add(self, name: Self.blobMessageName)

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
        // Bare IPv4 / localhost input (v0.4.14): LAN and
        // Tailscale dashboards are plain HTTP, so defaulting
        // them to https:// (or to a search) could never work —
        // "100.76.172.45:8090" must mean http://100.76.172.45:8090.
        // An explicit http:// URL already returned above,
        // untouched.
        if Self.looksLikeLocalHostAddress(text),
           let url = URL(string: "http://" + text) {
            return url
        }
        let looksLikeDomain = text.contains(".") && !text.contains(" ")
        if looksLikeDomain, let url = URL(string: "https://" + text) {
            return url
        }
        return settings.searchEngine.searchURL(for: text)
    }

    /// True for scheme-less input whose host part is an IPv4
    /// literal ("10.20.1.7", "100.76.172.45:8090/path") or
    /// "localhost" with a port/path. Plain words and regular
    /// domains are unaffected.
    static func looksLikeLocalHostAddress(_ text: String) -> Bool {
        guard !text.contains(" ") else { return false }
        let host = text.prefix { $0 != "/" && $0 != ":" && $0 != "?" }
        if host == "localhost" {
            return text.count > host.count
        }
        let octets = host.split(separator: ".")
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { part in
            !part.isEmpty && part.count <= 3
                && part.allSatisfy(\.isNumber)
                && (Int(part) ?? 999) <= 255
        }
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

    // MARK: - Shields (v0.4.14)

    /// Host of the page currently shown, for per-site features
    /// (the Shields panel). Nil on the start page and for archive
    /// (file://) tabs, where per-site state has no meaning.
    var currentHost: String? {
        guard !showsStartPage, archiveSnapshot == nil else { return nil }
        return webView.url?.host
    }

    /// Identifier of the Shields rule list currently attached to
    /// this tab's content controller; nil while none is attached.
    /// The list object is kept alongside: this SDK removes rule
    /// lists by object (`remove(_:)`), not by
    /// identifier.
    private(set) var appliedShieldsIdentifier: String?
    private var appliedShieldsList: WKContentRuleList?

    /// Attaches (or, with nil, detaches) the Shields content rule
    /// list. The previous list is removed first, so exactly one
    /// list is attached across recompiles. Pages that are already
    /// loaded keep their old rules until the next load — the
    /// caller reloads the active tab when the user toggles.
    func applyShields(list: WKContentRuleList?, identifier: String?) {
        let controller = webView.configuration.userContentController
        if let old = appliedShieldsList {
            controller.remove(old)
            appliedShieldsList = nil
            appliedShieldsIdentifier = nil
        }
        if let list, let identifier {
            controller.add(list)
            appliedShieldsList = list
            appliedShieldsIdentifier = identifier
        }
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

    // MARK: - Media detection & video long-press (v0.4.6, Playlist)

    /// Removes the probe script and message handler. The user
    /// content controller retains its handler, so without this a
    /// closed tab (and its web view) would leak for the session.
    func teardown() {
        delayedProbeTask?.cancel()
        let userContent = webView.configuration.userContentController
        userContent.removeScriptMessageHandler(forName: Self.mediaMessageName)
        userContent.removeScriptMessageHandler(forName: Self.blobMessageName)
        userContent.removeAllUserScripts()
        // A blob transfer cut off by the tab closing fails honestly
        // instead of sitting at "downloading" until the next launch.
        for (_, itemID) in blobTransfers {
            downloadStore?.failManualDownload(id: itemID, message: "タブが閉じられました")
        }
        blobTransfers.removeAll()
        for (_, itemID) in playlistBlobItems {
            playlistStore?.failBlobItem(itemID: itemID, message: "タブが閉じられました")
        }
        playlistBlobItems.removeAll()
        playlistBlobContext.removeAll()
        pendingBlobSave = nil
    }

    /// Collects the page's media right now: every <video>'s resolved
    /// source (currentSrc, src attribute, <source> children) plus
    /// anchor hrefs that point straight at media files.
    func collectPageMedia() async -> [DetectedMedia] {
        guard let raw = try? await webView.evaluateJavaScript(Self.mediaCollectScript),
              let json = raw as? String,
              let data = json.data(using: .utf8),
              let urls = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return urls.map { DetectedMedia(url: $0) }
    }

    /// Refreshes the published detection state (badge / menu add).
    /// Private tabs, the start page, archive views and non-http(s)
    /// pages never report media.
    func refreshDetectedMedia() async {
        guard !isPrivate, !showsStartPage, archiveSnapshot == nil,
              let scheme = webView.url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            if !detectedMedia.isEmpty { detectedMedia = [] }
            return
        }
        lastProbeRefresh = Date()
        let found = await collectPageMedia()
        if found != detectedMedia { detectedMedia = found }
    }

    /// One delayed re-scan (~3s after a navigation finishes) so
    /// lazily-loaded videos still get detected — exactly one extra
    /// pass, per the "no heavy polling" rule.
    private func scheduleDelayedProbe() {
        delayedProbeTask?.cancel()
        delayedProbeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            await self?.refreshDetectedMedia()
        }
    }

    /// The probe script reports DOM changes at most ~1/s; re-collect
    /// at most every 1.5s so a busy page cannot stampede the bridge.
    private func scheduleProbeRefresh() {
        guard Date().timeIntervalSince(lastProbeRefresh) > 1.5 else { return }
        Task { @MainActor [weak self] in
            await self?.refreshDetectedMedia()
        }
    }

    /// A long-press on a video ALWAYS ends in visible feedback.
    /// http(s) URLs open the add confirmation directly. A blob:
    /// URL is classified first (v0.4.14, RESEARCH_blob_playlist.md
    /// §2): a fetch probe in the frame that generated it separates
    /// plain Blobs (A — a real file, saveable through the bridge)
    /// from MediaSource handles (B — no bytes behind the URL; the
    /// real stream URL is looked up in the frame's Resource
    /// Timing instead). Every dead end lands in mediaNotice with
    /// its specific reason — the old blanket "保存できません
    /// （blob:）" was factually wrong for plain Blobs and is gone.
    private func handleVideoLongPress(url: String, title: String,
                                      frame: WKFrameInfo?, streams: [String]) {
        guard !isPrivate, !showsStartPage, archiveSnapshot == nil else { return }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("blob:") {
            resolveBlob(url: trimmed, frame: frame, streams: streams,
                        fromPicker: false)
            return
        }
        let media = DetectedMedia(url: trimmed)
        guard media.isHTTP else {
            mediaNotice = "この動画は保存できませんでした（URLを取得できません）"
            return
        }
        pendingLongPress = media
    }

    /// Picker entry point for a blob: row (v0.4.14): the picker
    /// collects from the main frame only, so classification runs
    /// there and the stream candidates are read from the main
    /// frame's Resource Timing at tap time.
    func resolveBlobFromPicker(_ media: DetectedMedia) {
        guard !isPrivate, !showsStartPage, archiveSnapshot == nil else { return }
        Task { @MainActor in
            let streams = await collectStreamCandidates()
            resolveBlob(url: media.url, frame: nil, streams: streams,
                        fromPicker: true)
        }
    }

    /// The blob classifier + resolver shared by the long-press and
    /// picker paths. `streams` are the generating frame's
    /// Resource-Timing media URLs (manifests first-class).
    private func resolveBlob(url: String, frame: WKFrameInfo?,
                             streams: [String], fromPicker: Bool) {
        Task { @MainActor in
            if let info = await classifyBlob(url: url, frame: frame),
               info.ok, info.size > 0 {
                // A: a plain Blob — a real file behind the URL.
                if fromPicker {
                    startBlobSaveToPlaylist(url: url, frame: frame,
                                            title: pageTitle)
                    tabNotice = "Playlistへ保存を開始しました"
                } else {
                    pendingBlobSave = (url: url, frame: frame, title: pageTitle)
                    pendingLongPress = DetectedMedia(url: url)
                }
                return
            }
            // B: MediaSource — the URL itself holds no bytes. Find
            // the real stream the player actually fetched.
            let manifests = streams.filter { streamExtension($0) == "m3u8" }
            if manifests.count == 1 {
                offerStream(manifests[0], fromPicker: fromPicker)
            } else if manifests.count > 1 {
                mediaNotice = "この動画のストリーム候補が複数あります。保存バッジのリストから選んでください"
            } else if let dash = streams.first(where: { streamExtension($0) == "mpd" }) {
                _ = dash
                mediaNotice = "この動画形式（DASH）は保存に未対応です"
            } else if let progressive = streams.first(where: {
                ["mp4", "mov", "m4v", "webm"].contains(streamExtension($0))
            }) {
                offerStream(progressive, fromPicker: fromPicker)
            } else {
                mediaNotice = "この動画は保存できませんでした（実URLを検出できません）"
            }
        }
    }

    /// A stream URL discovered behind an MSE blob: from a long
    /// press it goes through the usual add confirmation; from the
    /// picker (where the user already chose the item) it is added
    /// directly.
    private func offerStream(_ streamURL: String, fromPicker: Bool) {
        let media = DetectedMedia(url: streamURL)
        if fromPicker {
            if playlistStore?.add(title: pageTitle, url: streamURL,
                                  pageURL: currentURLString) == true {
                tabNotice = media.isM3U8
                    ? "Playlistに追加しました（HLSで保存します）"
                    : "Playlistに追加しました"
            } else {
                tabNotice = "すでにPlaylistにあります"
            }
        } else {
            pendingLongPress = media
        }
    }

    private func streamExtension(_ urlString: String) -> String {
        URL(string: urlString)?.pathExtension.lowercased() ?? ""
    }

    /// The discriminator (research §2.2): fetch the blob URL in
    /// the frame that generated it. Success with size > 0 means a
    /// plain Blob; a MediaSource URL has no bytes, so the fetch
    /// fails. Runs as an async JS function via callAsyncJavaScript
    /// (evaluateJavaScript would not await the promise).
    private func classifyBlob(url: String, frame: WKFrameInfo?) async
        -> (ok: Bool, size: Int64, type: String)? {
        let body = """
            try {
              const response = await fetch(blobURL);
              const blob = await response.blob();
              return JSON.stringify({ ok: true, size: blob.size,
                                      type: blob.type || '' });
            } catch (e) {
              return JSON.stringify({ ok: false, size: 0, type: '' });
            }
            """
        guard let raw = try? await webView.callAsyncJavaScript(
                body, arguments: ["blobURL": url], inFrame: frame,
                in: .default),
              let json = raw as? String,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }
        return (ok: dict["ok"] as? Bool ?? false,
                size: (dict["size"] as? NSNumber)?.int64Value ?? 0,
                type: dict["type"] as? String ?? "")
    }

    /// This frame's Resource-Timing media URLs (main frame), read
    /// on demand for the picker path: manifests plus progressive
    /// files the player fetched.
    private func collectStreamCandidates() async -> [String] {
        let script = #"""
            (function () {
              var out = [];
              var seen = {};
              try {
                var entries = performance.getEntriesByType('resource') || [];
                for (var i = 0; i < entries.length; i++) {
                  var name = entries[i].name || '';
                  if (/\.(m3u8|mpd|mp4|mov|m4v|webm)(\?|#|$)/i.test(name)
                      && !seen[name]) {
                    seen[name] = 1;
                    out.push(name);
                  }
                }
              } catch (e) {}
              return JSON.stringify(out);
            })()
            """#
        guard let raw = try? await webView.evaluateJavaScript(script),
              let json = raw as? String,
              let data = json.data(using: .utf8),
              let urls = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return urls
    }

    /// Starts a plain-Blob → Playlist transfer: the probe script
    /// in the generating frame fetches the blob and streams it
    /// back in chunks (plstart / plchunk / plend messages). No
    /// size cap — the user's standing call is unlimited, and the
    /// staging file keeps memory flat.
    func startBlobSaveToPlaylist(url: String, frame: WKFrameInfo?, title: String) {
        guard playlistStore != nil else { return }
        let transfer = UUID().uuidString
        playlistBlobContext[transfer] = (title: title, pageURL: currentURLString)
        let js = "window.__sbSaveBlobToPlaylist && "
            + "window.__sbSaveBlobToPlaylist(\(Self.jsStringLiteral(url)), "
            + "\(Self.jsStringLiteral(transfer)))"
        webView.evaluateJavaScript(js, inFrame: frame, in: .default) { [weak self] result in
            if case .failure = result {
                Task { @MainActor in
                    guard let self else { return }
                    self.playlistBlobContext[transfer] = nil
                    self.mediaNotice = "この動画は保存できませんでした（ページが変わっています）"
                }
            }
        }
    }

    /// ContentView's add confirmation for a classified plain Blob:
    /// the pending context was captured at long-press time.
    func confirmPendingBlobSave() {
        guard let pending = pendingBlobSave else { return }
        pendingBlobSave = nil
        startBlobSaveToPlaylist(url: pending.url, frame: pending.frame,
                                title: pending.title)
        tabNotice = "Playlistへ保存を開始しました"
    }

    /// Native end of the blob→Playlist stream (probe script,
    /// snapMedia messages plstart / plchunk / plend / plerror).
    func handlePlaylistBlobMessage(_ body: [String: Any]) {
        guard let store = playlistStore,
              let transfer = body["transfer"] as? String else { return }
        switch body["type"] as? String ?? "" {
        case "plstart":
            guard let context = playlistBlobContext[transfer] else { return }
            let mime = body["mime"] as? String ?? ""
            let size = (body["size"] as? NSNumber)?.int64Value
            let fileName = "video" + Self.fileExtension(forMime: mime)
            let itemID = store.beginBlobItem(title: context.title,
                                             url: body["url"] as? String ?? "",
                                             pageURL: context.pageURL,
                                             fileName: fileName,
                                             expectedBytes: size)
            playlistBlobItems[transfer] = itemID
        case "plchunk":
            guard let itemID = playlistBlobItems[transfer],
                  let base64 = body["data"] as? String,
                  let data = Data(base64Encoded: base64) else { return }
            store.appendBlobChunk(itemID: itemID, data: data)
        case "plend":
            guard let itemID = playlistBlobItems.removeValue(forKey: transfer)
            else { return }
            playlistBlobContext[transfer] = nil
            store.finishBlobItem(itemID: itemID)
            tabNotice = "Playlistに保存しました"
        case "plerror":
            playlistBlobContext[transfer] = nil
            if let itemID = playlistBlobItems.removeValue(forKey: transfer) {
                store.failBlobItem(itemID: itemID,
                                   message: "ページからの読み取りに失敗しました")
            } else {
                mediaNotice = "この動画は保存できませんでした（読み取りに失敗）"
            }
        default:
            break
        }
    }

    /// File extension for a blob's MIME type (the saved file's
    /// name is the item id plus this extension).
    static func fileExtension(forMime mime: String) -> String {
        switch mime.lowercased() {
        case "video/mp4": return ".mp4"
        case "video/quicktime": return ".mov"
        case "video/webm": return ".webm"
        case "video/x-m4v", "video/m4v": return ".m4v"
        case "audio/mpeg": return ".mp3"
        case "audio/mp4", "audio/x-m4a": return ".m4a"
        case "application/pdf": return ".pdf"
        case "image/png": return ".png"
        case "image/jpeg": return ".jpg"
        default: return ".mp4"
        }
    }

    /// A JS string literal for `value` (JSON encoding is a valid
    /// JS string literal for this use).
    static func jsStringLiteral(_ value: String) -> String {
        let quote = "\""
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8) else {
            return quote + quote
        }
        return String(text.dropFirst().dropLast())
    }

    /// Headers for native media downloads (v0.4.14): this tab's
    /// cookies filtered to the target host (the SelfContainedHTML
    /// pattern) plus the WebView's user agent. PlaylistStore adds
    /// the Referer itself.
    func downloadHeaders(for url: URL) async -> [String: String] {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
        var headers: [String: String] = [:]
        if let host = url.host {
            let matching = cookies.filter { cookie in
                let domain = cookie.domain.hasPrefix(".")
                    ? String(cookie.domain.dropFirst()) : cookie.domain
                return host == domain || host.hasSuffix("." + domain)
            }
            if !matching.isEmpty,
               let header = HTTPCookie.requestHeaderFields(with: matching)["Cookie"] {
                headers["Cookie"] = header
            }
        }
        var userAgent = webView.customUserAgent
        if userAgent == nil,
           let value = try? await webView.evaluateJavaScript("navigator.userAgent") {
            userAgent = value as? String
        }
        if let userAgent, !userAgent.isEmpty {
            headers["User-Agent"] = userAgent
        }
        return headers
    }

    /// blob: download bridge (v0.4.10). WKWebView cannot download
    /// blob: URLs at all — clicking a blob download link (what most
    /// in-browser file generators use: PDF converters, image tools,
    /// jsPDF-style exporters) simply does nothing, which read to the
    /// user as 「ダウンロードできない」. This script intercepts clicks
    /// on blob: anchors in the capture phase (so it also catches
    /// anchors the page appends and clicks programmatically),
    /// fetches the blob inside the page, and streams it to native in
    /// 512KB base64 chunks that are appended to a staging file on
    /// disk — memory stays flat regardless of file size. The 100MB
    /// cap is reported honestly instead of pretending.
    private static let blobDownloadScript = #"""
    (function () {
      if (window.__snapBlobBridge) return;
      window.__snapBlobBridge = true;
      var CAP = 100 * 1024 * 1024;
      var CHUNK = 512 * 1024;
      var seq = 0;
      function post(msg) {
        try { window.webkit.messageHandlers.snapBlob.postMessage(msg); } catch (e) {}
      }
      function extFor(mime) {
        switch ((mime || '').toLowerCase()) {
          case 'application/pdf': return '.pdf';
          case 'application/zip': return '.zip';
          case 'image/png': return '.png';
          case 'image/jpeg': return '.jpg';
          case 'text/plain': return '.txt';
          default: return '';
        }
      }
      function sendBlob(blob, name) {
        if (blob.size > CAP) { post({ type: 'toobig', name: name }); return; }
        if (!name) name = 'download' + extFor(blob.type);
        var id = 'blob' + (++seq) + '-' + Date.now();
        post({ type: 'start', id: id, name: name, size: blob.size, mime: blob.type || '' });
        var offset = 0;
        function step() {
          if (offset >= blob.size) { post({ type: 'end', id: id }); return; }
          var slice = blob.slice(offset, offset + CHUNK);
          var reader = new FileReader();
          reader.onload = function () {
            var result = String(reader.result || '');
            var comma = result.indexOf(',');
            post({ type: 'chunk', id: id, data: comma >= 0 ? result.slice(comma + 1) : '' });
            offset += slice.size;
            step();
          };
          reader.onerror = function () { post({ type: 'error', id: id }); };
          reader.readAsDataURL(slice);
        }
        step();
      }
      document.addEventListener('click', function (event) {
        var el = event.target;
        while (el && el !== document && el.tagName !== 'A') el = el.parentElement;
        if (!el || el.tagName !== 'A') return;
        var href = el.href || '';
        if (href.toLowerCase().indexOf('blob:') !== 0) return;
        event.preventDefault();
        event.stopPropagation();
        var name = el.getAttribute('download') || '';
        fetch(href).then(function (r) { return r.blob(); }).then(function (blob) {
          sendBlob(blob, name);
        }).catch(function () { post({ type: 'error', id: '' }); });
      }, true);
    })();
    """#

    /// Collect script (run on demand via evaluateJavaScript):
    /// resolves every video's source the same way the long-press
    /// probe does, plus media-file anchor hrefs.
    private static let mediaCollectScript = #"""
    (function () {
      var out = [];
      var seen = {};
      function push(u) {
        if (!u) return;
        var abs = u;
        try { abs = new URL(u, document.baseURI).href; } catch (e) { return; }
        if (seen[abs]) return;
        seen[abs] = 1;
        out.push(abs);
      }
      var videos = document.querySelectorAll('video');
      for (var i = 0; i < videos.length; i++) {
        var v = videos[i];
        if (v.currentSrc) push(v.currentSrc);
        var attr = v.getAttribute('src');
        if (attr) push(attr);
        var sources = v.querySelectorAll('source');
        for (var j = 0; j < sources.length; j++) {
          push(sources[j].getAttribute('src') || '');
        }
      }
      var links = document.querySelectorAll('a[href]');
      for (var k = 0; k < links.length; k++) {
        var href = links[k].getAttribute('href') || '';
        if (/\.(mp4|mov|m4v|webm)([?#]|$)/i.test(href)) push(href);
      }
      // Stream manifests the page's player fetched (v0.4.14):
      // behind an MSE blob:, the .m3u8 in the Resource Timing
      // ledger is the saveable URL. Names survive cross-origin
      // (only sizes/timings are zeroed without TAO).
      try {
        var entries = performance.getEntriesByType('resource') || [];
        for (var m = 0; m < entries.length; m++) {
          var name = entries[m].name || '';
          if (/\.(m3u8|mpd)([?#]|$)/i.test(name)) push(name);
        }
      } catch (e) {}
      return JSON.stringify(out);
    })()
    """#

    /// Probe script (injected into every frame at document end):
    ///
    /// Long-press: a touch held ~0.45s within 10pt on (or over) a
    /// <video> resolves that video — the touch target itself, its
    /// ancestors, a wrapped descendant, or the smallest video whose
    /// rect contains the point (covering sibling overlays) — and
    /// posts its currentSrc / src / <source src>. All listeners are
    /// passive and never preventDefault, so taps, scrolling and the
    /// native media controls are untouched; moving >10pt cancels.
    ///
    /// DOM changes: a MutationObserver debounced to ~1 post/s asks
    /// the native side to re-collect (it throttles further).
    private static let mediaProbeScript = #"""
    (function () {
      if (window.__sbMediaProbe) return;
      window.__sbMediaProbe = true;
      function post(message) {
        try {
          window.webkit.messageHandlers.snapMedia.postMessage(message);
        } catch (e) {}
      }
      // Resource Timing collection (v0.4.14): manifests the
      // player fetches are the real URLs behind MSE blob:
      // playback. The buffer is widened up front and a
      // PerformanceObserver keeps its own list, so entries are
      // not lost when the page overflows the default buffer.
      window.__sbStreams = [];
      try { performance.setResourceTimingBufferSize(1000); } catch (e) {}
      function noteStream(name) {
        if (!name) return;
        if (!/\.(m3u8|mpd)([?#]|$)/i.test(name)) return;
        if (window.__sbStreams.indexOf(name) >= 0) return;
        if (window.__sbStreams.length < 100) window.__sbStreams.push(name);
      }
      if (window.PerformanceObserver) {
        try {
          new PerformanceObserver(function (list) {
            var entries = list.getEntries();
            for (var i = 0; i < entries.length; i++) {
              noteStream(entries[i].name || '');
            }
          }).observe({ entryTypes: ['resource'] });
        } catch (e) {}
      }
      function streamCandidates() {
        var out = [];
        var seen = {};
        function add(u) {
          if (u && !seen[u]) { seen[u] = 1; out.push(u); }
        }
        for (var i = 0; i < window.__sbStreams.length; i++) {
          add(window.__sbStreams[i]);
        }
        try {
          var entries = performance.getEntriesByType('resource') || [];
          for (var j = 0; j < entries.length; j++) {
            var n = entries[j].name || '';
            if (/\.(m3u8|mpd|mp4|mov|m4v|webm)([?#]|$)/i.test(n)) add(n);
          }
        } catch (e) {}
        return out;
      }
      // Plain-Blob -> Playlist transfer (v0.4.14): native asks
      // this frame to stream one of ITS blob URLs back in 512KB
      // base64 chunks — the blob only exists in the document
      // that created it, so the fetch must happen here. No size
      // cap (the user's standing call is unlimited); chunks go
      // to a staging file on the native side, memory stays flat.
      window.__sbSaveBlobToPlaylist = function (url, transfer) {
        fetch(url).then(function (r) { return r.blob(); }).then(function (blob) {
          post({ type: 'plstart', transfer: transfer, url: url,
                 size: blob.size, mime: blob.type || '' });
          var CHUNK = 512 * 1024;
          var offset = 0;
          function step() {
            if (offset >= blob.size) {
              post({ type: 'plend', transfer: transfer });
              return;
            }
            var slice = blob.slice(offset, offset + CHUNK);
            var reader = new FileReader();
            reader.onload = function () {
              var result = String(reader.result || '');
              var comma = result.indexOf(',');
              post({ type: 'plchunk', transfer: transfer,
                     data: comma >= 0 ? result.slice(comma + 1) : '' });
              offset += slice.size;
              step();
            };
            reader.onerror = function () {
              post({ type: 'plerror', transfer: transfer });
            };
            reader.readAsDataURL(slice);
          }
          step();
        }).catch(function () {
          post({ type: 'plerror', transfer: transfer });
        });
      };
      function videoURL(v) {
        if (v.currentSrc) return v.currentSrc;
        var attr = v.getAttribute('src');
        if (attr) return v.src;
        var source = v.querySelector('source[src]');
        if (source) return source.src;
        return '';
      }
      function findVideo(x, y, el) {
        var node = el;
        while (node && node !== document) {
          if (node.tagName === 'VIDEO') return node;
          node = node.parentElement;
        }
        if (el && el.querySelector) {
          var inner = el.querySelector('video');
          if (inner) return inner;
        }
        var videos = document.querySelectorAll('video');
        var best = null;
        var bestArea = Infinity;
        for (var i = 0; i < videos.length; i++) {
          var r = videos[i].getBoundingClientRect();
          if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) {
            var area = r.width * r.height;
            if (area < bestArea) { bestArea = area; best = videos[i]; }
          }
        }
        return best;
      }
      var timer = null;
      var startX = 0;
      var startY = 0;
      var target = null;
      function clearTimer() {
        if (timer) { clearTimeout(timer); timer = null; }
        target = null;
      }
      document.addEventListener('touchstart', function (e) {
        clearTimer();
        if (e.touches.length !== 1) return;
        var touch = e.touches[0];
        startX = touch.clientX;
        startY = touch.clientY;
        var el = document.elementFromPoint(startX, startY) || e.target;
        var video = findVideo(startX, startY, el);
        if (!video) return;
        target = video;
        timer = setTimeout(function () {
          timer = null;
          if (!target) return;
          post({ type: 'longpress',
                 url: videoURL(target) || '',
                 title: document.title || '',
                 streams: streamCandidates() });
          target = null;
        }, 450);
      }, { passive: true, capture: true });
      document.addEventListener('touchmove', function (e) {
        if (!timer) return;
        var touch = e.touches[0];
        if (Math.abs(touch.clientX - startX) > 10 ||
            Math.abs(touch.clientY - startY) > 10) {
          clearTimer();
        }
      }, { passive: true, capture: true });
      document.addEventListener('touchend', clearTimer,
        { passive: true, capture: true });
      document.addEventListener('touchcancel', clearTimer,
        { passive: true, capture: true });
      var pending = null;
      function notifyChanged() {
        if (pending) return;
        pending = setTimeout(function () {
          pending = null;
          post({ type: 'changed' });
        }, 1000);
      }
      if (window.MutationObserver && document.documentElement) {
        var observer = new MutationObserver(function (mutations) {
          for (var i = 0; i < mutations.length; i++) {
            if (mutations[i].addedNodes.length ||
                mutations[i].removedNodes.length) {
              notifyChanged();
              return;
            }
          }
        });
        observer.observe(document.documentElement,
                         { childList: true, subtree: true });
      }
      // Context-element report (v0.4.9): WKContextMenuElementInfo
      // carries no image URL, so the native context menu resolves
      // images through the element under the most recent touch.
      // Passive, like everything else in this probe.
      document.addEventListener('touchstart', function (e) {
        if (e.touches.length !== 1) return;
        var touch = e.touches[0];
        var el = document.elementFromPoint(touch.clientX, touch.clientY)
                 || e.target;
        if (!el) return;
        var link = '';
        var node = el;
        while (node && node !== document) {
          if (node.tagName === 'A' && node.href) { link = node.href; break; }
          node = node.parentElement;
        }
        var image = '';
        if (el.tagName === 'IMG') {
          image = el.currentSrc || el.src || '';
        } else if (el.querySelector) {
          var img = el.querySelector('img');
          if (img) image = img.currentSrc || img.src || '';
        }
        if (link || image) {
          post({ type: 'touchinfo', link: link, image: image });
        }
      }, { passive: true, capture: true });
    })()
    """#

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
        // Never write the frame of a HOSTED web view by hand
        // (v0.4.10): SwiftUI's container owns that frame, and a
        // manual write is how a stale, larger-than-window size used
        // to get into the layout and stick (the page then rendered
        // wider than a floating window). Only off-screen background
        // web views — which SwiftUI is not laying out — get the
        // manual resize, and the container forces the correct size
        // the moment such a tab is hosted.
        if size.width > 0, webView.window == nil, webView.bounds.size != size {
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
        /// Bundled-media tally "saved/attempted" (v0.4.13 phase
        /// 2b), nil when the page had no direct-file media.
        var mediaBundled: String?
        /// The resource budget stopped the archive fetch early;
        /// the completion message says so instead of staying
        /// silent about the shortfall.
        var assetsCapped: Bool
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

            // 0) Prime lazy loading (v0.4.13): scroll through the
            // page once so lazy images fire before ANY capture
            // reads the page, then restore the scroll position.
            // Best-effort and time-capped — never blocks the snap.
            await SelfContainedHTML.primeLazyLoads(in: webView)

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

            // 5) Self-contained HTML (styles/images inlined for offline view),
            //    plus any bundled direct-file media (phase 2b), which
            //    arrives as temp files and is moved into the folder
            //    by the store — never loaded into memory here.
            var fullHTMLData: Data?
            var assetsNote: String?
            var mediaFiles: [(name: String, tempURL: URL)] = []
            var mediaAttempted = 0
            var assetsCapped = false
            do {
                let built = try await SelfContainedHTML.build(from: webView)
                fullHTMLData = built.data
                assetsNote = "\(built.inlined)/\(built.total)"
                assetsCapped = built.assetsCapped
                mediaAttempted = built.mediaAttempted
                mediaFiles = built.media.map { (name: $0.fileName, tempURL: $0.tempFile) }
            } catch {
                failures.append("自己完結HTML: \(error.localizedDescription)")
            }

            var result = SnapResult(title: title,
                                    url: sourceURL.absoluteString,
                                    imageBytes: nil, archiveBytes: nil,
                                    textChars: nil, htmlBytes: nil,
                                    fullHTMLBytes: nil, assetsInlined: assetsNote,
                                    mediaBundled: nil, assetsCapped: assetsCapped,
                                    failures: failures)
            do {
                let saved = try store.save(title: title,
                                           url: sourceURL.absoluteString,
                                           imageData: imageData,
                                           archiveData: archiveData,
                                           text: text,
                                           htmlData: htmlData,
                                           fullHTMLData: fullHTMLData,
                                           mediaFiles: mediaFiles)
                result.imageBytes = saved.imageBytes
                result.archiveBytes = saved.archiveBytes
                result.textChars = saved.textChars
                result.htmlBytes = saved.htmlBytes
                result.fullHTMLBytes = saved.fullHTMLBytes
                if mediaAttempted > 0 {
                    result.mediaBundled = "\(saved.mediaCount)/\(mediaAttempted)"
                }
                result.failures.append(contentsOf: saved.failures)
            } catch {
                result.failures.append("保存: \(error.localizedDescription)")
            }
            // Any media temp the store did not consume (save threw
            // before the moves) must not be left behind.
            for media in mediaFiles
            where FileManager.default.fileExists(atPath: media.tempURL.path) {
                try? FileManager.default.removeItem(at: media.tempURL)
            }

            lastSnapResult = result
            isSnapping = false
        }
    }

    /// Full-page capture by temporarily growing the web view to the page's
    /// content height, then snapshotting the whole frame in slices
    /// stitched at 2x (captureFullHeight). Pages taller than the cap
    /// fall back to the visible viewport (honest limitation).
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

        // Restore target (v0.4.10): a hosted web view goes back to
        // its container's bounds — the size SwiftUI currently wants —
        // not the frame saved before the grow, which is stale if the
        // window was resized while the capture ran. (The container's
        // layoutSubviews would correct a wrong restore on the next
        // layout pass anyway; this keeps it right immediately.)
        let restoreFrame = webView.superview?.bounds ?? originalFrame
        do {
            let image = try await Self.captureFullHeight(of: webView)
            webView.frame = restoreFrame
            scrollView.contentOffset = originalOffset
            return image
        } catch {
            webView.frame = restoreFrame
            scrollView.contentOffset = originalOffset
            return try await snapshotCurrentView()
        }
    }

    /// Captures the (already frame-grown) web view in horizontal
    /// slices and stitches them into one full-page image
    /// (v0.4.13). takeSnapshot renders at the window's display
    /// scale — 2x on a retina iPad — but a single snapshot of a
    /// very tall page can exceed the renderer's texture limits
    /// and fail or silently degrade to a smaller render; slicing
    /// keeps each render bounded (4,000pt) so the 2x result
    /// actually holds for tall pages. The stitched canvas targets
    /// 2x; when the estimated pixel memory is too large it drops
    /// to 1x instead (the honest fallback) rather than risking
    /// the process. Any failure throws, and the caller falls back
    /// to the visible-viewport snapshot, as before.
    private static func captureFullHeight(of webView: WKWebView) async throws -> UIImage {
        let bounds = webView.bounds
        let displayScale = webView.traitCollection.displayScale
        let targetScale: CGFloat = displayScale >= 2 ? 2 : max(displayScale, 1)
        let estimatedBytes = Double(bounds.width) * Double(bounds.height)
            * Double(targetScale * targetScale) * 4
        let renderScale: CGFloat = estimatedBytes <= 240_000_000 ? targetScale : 1

        let sliceHeight: CGFloat = 4_000
        var slices: [(y: CGFloat, image: UIImage)] = []
        var y: CGFloat = 0
        while y < bounds.height {
            let height = min(sliceHeight, bounds.height - y)
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: 0, y: y, width: bounds.width, height: height)
            let image = try await takeSnapshot(of: webView, configuration: config)
            slices.append((y, image))
            y += height
        }
        guard let first = slices.first else {
            throw NSError(domain: "SnapBrowser", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "スナップショット撮影に失敗"])
        }
        if slices.count == 1 { return first.image }

        let format = UIGraphicsImageRendererFormat()
        format.scale = renderScale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
        return renderer.image { _ in
            for slice in slices {
                slice.image.draw(in: CGRect(x: 0, y: slice.y,
                                            width: bounds.width,
                                            height: slice.image.size.height))
            }
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
            if url.scheme == "http" || url.scheme == "https" {
                // New page: the previous page's media detections and
                // any pending long-press no longer apply.
                self.detectedMedia = []
                self.pendingLongPress = nil
                self.delayedProbeTask?.cancel()
                // The previous page's inline document is gone too;
                // the response policy re-marks it if the new page is
                // itself a document (v0.4.10).
                self.currentDocumentName = nil
                self.currentDocumentURL = nil
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFinish navigation: WKNavigation!) {
        let url = webView.url
        let title = webView.title
        Task { @MainActor in
            self.loadError = nil
            self.capturePreview()
            await self.refreshDetectedMedia()
            self.scheduleDelayedProbe()
            guard let url, url.scheme == "http" || url.scheme == "https",
                  self.archiveSnapshot == nil, !self.showsStartPage else { return }
            self.onVisit?(title ?? url.host ?? url.absoluteString, url.absoluteString)
        }
    }

    // MARK: Load failures (v0.4.9) — an error card, never a blank page

    nonisolated func webView(_ webView: WKWebView,
                             didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        recordLoadFailure(error)
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFail navigation: WKNavigation!,
                             withError error: Error) {
        recordLoadFailure(error)
    }

    private nonisolated func recordLoadFailure(_ error: Error) {
        let nsError = error as NSError
        // Benign outcomes that are NOT failures and must never
        // flash the error card:
        // - NSURLErrorCancelled (-999): the user stopped the load,
        //   or a new navigation replaced it.
        // - WebKitErrorDomain 204 (Plug-in handled load): a media
        //   plug-in took over the load — exactly what a direct
        //   .mp4/.mp3 link does in WKWebView, where the plug-in
        //   then plays the file. Up to v0.4.12 this was treated as
        //   a failure and the card showed 「プラグインが読み込みを
        //   処理」 over a video that never got to play (v0.4.13
        //   fix — the user's direct-mp4 report).
        // - WebKitErrorDomain 102 (Frame load interrupted by
        //   policy change): our own policy decisions — external
        //   scheme hand-off, download conversion — superseded the
        //   load on purpose.
        if nsError.domain == NSURLErrorDomain
            && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain"
            && (nsError.code == 204 || nsError.code == 102) { return }
        let message = error.localizedDescription
        Task { @MainActor in
            self.loadError = message
        }
    }

    // MARK: Navigation policy (v0.4.9) — external schemes + downloads

    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        let inPageSchemes: Set<String> = ["http", "https", "about", "data", "file", "blob"]
        if !scheme.isEmpty, !inPageSchemes.contains(scheme) {
            // tel: / mailto: / sms: / app deep links: hand over to
            // the OS and never navigate the web view there. A failed
            // hand-off is reported, not swallowed.
            decisionHandler(.cancel)
            Task { @MainActor in
                UIApplication.shared.open(url, options: [:]) { success in
                    if !success {
                        Task { @MainActor in
                            self.tabNotice = "このリンクを開けるアプリがありませんでした"
                        }
                    }
                }
            }
            return
        }
        decisionHandler(.allow)
    }

    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationResponse: WKNavigationResponse,
                             decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().contains("attachment") {
            decisionHandler(.download)
            return
        }
        // Inline-displayable document (v0.4.10): the response will be
        // shown, not downloaded — remember it so the ⋯ menu can offer
        // 「このファイルをダウンロード」 for the displayed file.
        if navigationResponse.isForMainFrame,
           let url = navigationResponse.response.url,
           Self.isInlineDocument(url: url, mimeType: navigationResponse.response.mimeType) {
            let name = Self.documentName(url: url, mimeType: navigationResponse.response.mimeType)
            Task { @MainActor in
                self.currentDocumentName = name
                self.currentDocumentURL = url
            }
        }
        decisionHandler(.allow)
    }

    /// MIME types / extensions treated as a downloadable document
    /// when the web view displays them inline instead of downloading.
    /// (Types WebKit cannot display never reach here — they already
    /// became WKDownloads above. The realistic inline cases are PDF,
    /// plain text, and office files served with a displayable type.)
    /// Media the web view PLAYS inline (video/*, audio/* — v0.4.13)
    /// counts as well: playback stays the response policy's answer
    /// (canShowMIMEType is true for playable media, so it is never
    /// forced into a download above), and this only ADDS the
    /// 「このファイルをダウンロード」 affordance for the playing file.
    // nonisolated: these pure helpers are called from the
    // nonisolated navigation-response delegate (v0.4.10 fix — as
    // plain statics on the @MainActor class they were themselves
    // main-actor-isolated and the call was a compile error).
    nonisolated private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "epub", "csv", "tsv", "rtf", "odt", "ods", "odp",
    ]

    nonisolated private static let mediaExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mp3", "m4a", "aac", "wav", "flac", "ogg", "webm",
    ]

    nonisolated private static func isInlineDocument(url: URL, mimeType: String?) -> Bool {
        let mime = mimeType?.lowercased() ?? ""
        if mime == "application/pdf" { return true }
        if mime.hasPrefix("video/") || mime.hasPrefix("audio/") { return true }
        let ext = url.pathExtension.lowercased()
        return documentExtensions.contains(ext) || mediaExtensions.contains(ext)
    }

    nonisolated private static func documentName(url: URL, mimeType: String?) -> String {
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/" { return last.removingPercentEncoding ?? last }
        if mimeType?.lowercased() == "application/pdf" { return "document.pdf" }
        return "document"
    }

    /// ⋯ menu 「このファイルをダウンロード」 (v0.4.10): re-fetches the
    /// document this tab is displaying (a PDF opened inline, …) as a
    /// real download through the web view, so the request carries
    /// the page's cookies/session, and hands it to the download
    /// store via the usual handler. Honest limit: the file is
    /// fetched with a fresh GET — a document that only exists as
    /// the result of a POST may not come back identically.
    func downloadCurrentDocument() {
        guard let url = currentDocumentURL ?? webView.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        // startDownload only exists in completion-handler / async
        // form — there is no synchronous variant. (In this SDK the
        // handler's WKDownload is non-optional.)
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            Task { @MainActor in
                self?.downloadHandler?(download)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             navigationAction: WKNavigationAction,
                             didBecome download: WKDownload) {
        Task { @MainActor in
            self.downloadHandler?(download)
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             navigationResponse: WKNavigationResponse,
                             didBecome download: WKDownload) {
        Task { @MainActor in
            self.downloadHandler?(download)
        }
    }

    // MARK: Authentication (v0.4.9) — Basic/Digest credential dialog

    nonisolated func webView(_ webView: WKWebView,
                             didReceive challenge: URLAuthenticationChallenge,
                             completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        let credentialMethods: Set<String> = [
            NSURLAuthenticationMethodHTTPBasic,
            NSURLAuthenticationMethodHTTPDigest,
            NSURLAuthenticationMethodNTLM,
            NSURLAuthenticationMethodHTMLForm
        ]
        guard credentialMethods.contains(method) else {
            // Server trust and everything else: WebKit's default
            // validation applies — never rubber-stamp certificates.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // A retry after a rejected credential: don't loop dialogs.
        guard challenge.previousFailureCount == 0 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let host = challenge.protectionSpace.host
        let realm = challenge.protectionSpace.realm
        Task { @MainActor in
            // One dialog at a time; a second challenge is cancelled
            // rather than stacked.
            guard self.authRequest == nil else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            self.authRequest = AuthRequest(host: host, realm: realm) { credential in
                if let credential {
                    completionHandler(.useCredential, credential)
                } else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            }
        }
    }
}

// MARK: - JS panel / auth requests (v0.4.9)
//
// WebKit completion handlers must be called exactly once or the
// page's JavaScript hangs forever. These request objects own the
// handler, ignore double responses, and — as a last resort — answer
// with the "cancel" value from deinit if the UI dropped them.

final class JSPanelRequest: Identifiable {
    enum Kind { case alert, confirm, prompt }
    let id = UUID()
    let kind: Kind
    let message: String
    let defaultText: String
    private var responded = false
    private let alertHandler: (() -> Void)?
    private let confirmHandler: ((Bool) -> Void)?
    private let promptHandler: ((String?) -> Void)?

    private init(kind: Kind, message: String, defaultText: String,
                 alertHandler: (() -> Void)? = nil,
                 confirmHandler: ((Bool) -> Void)? = nil,
                 promptHandler: ((String?) -> Void)? = nil) {
        self.kind = kind
        self.message = message
        self.defaultText = defaultText
        self.alertHandler = alertHandler
        self.confirmHandler = confirmHandler
        self.promptHandler = promptHandler
    }

    static func alert(message: String, handler: @escaping () -> Void) -> JSPanelRequest {
        JSPanelRequest(kind: .alert, message: message, defaultText: "", alertHandler: handler)
    }

    static func confirm(message: String, handler: @escaping (Bool) -> Void) -> JSPanelRequest {
        JSPanelRequest(kind: .confirm, message: message, defaultText: "", confirmHandler: handler)
    }

    static func prompt(message: String, defaultText: String,
                       handler: @escaping (String?) -> Void) -> JSPanelRequest {
        JSPanelRequest(kind: .prompt, message: message, defaultText: defaultText,
                       promptHandler: handler)
    }

    func respondAlert() {
        guard !responded else { return }
        responded = true
        alertHandler?()
    }

    func respondConfirm(_ value: Bool) {
        guard !responded else { return }
        responded = true
        confirmHandler?(value)
    }

    func respondPrompt(_ value: String?) {
        guard !responded else { return }
        responded = true
        promptHandler?(value)
    }

    deinit {
        guard !responded else { return }
        alertHandler?()
        confirmHandler?(false)
        promptHandler?(nil)
    }
}

final class AuthRequest: Identifiable {
    let id = UUID()
    let host: String
    let realm: String?
    private var responded = false
    private let handler: (URLCredential?) -> Void

    init(host: String, realm: String?, handler: @escaping (URLCredential?) -> Void) {
        self.host = host
        self.realm = realm
        self.handler = handler
    }

    func respond(user: String, password: String) {
        guard !responded else { return }
        responded = true
        handler(URLCredential(user: user, password: password, persistence: .forSession))
    }

    func cancel() {
        guard !responded else { return }
        responded = true
        handler(nil)
    }

    deinit {
        if !responded { handler(nil) }
    }
}

// MARK: - WKUIDelegate (v0.4.9): JS panels, new-window links, context menus

extension BrowserTab: WKUIDelegate {
    nonisolated func webView(_ webView: WKWebView,
                             runJavaScriptAlertPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            self.jsPanel = .alert(message: message, handler: completionHandler)
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             runJavaScriptConfirmPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            self.jsPanel = .confirm(message: message, handler: completionHandler)
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             runJavaScriptTextInputPanelWithPrompt prompt: String,
                             defaultText: String?,
                             initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping (String?) -> Void) {
        Task { @MainActor in
            self.jsPanel = .prompt(message: prompt, defaultText: defaultText ?? "",
                                   handler: completionHandler)
        }
    }

    /// window.open / target="_blank": WebKit hands us the request and
    /// expects a web view back; the standard browser answer is a new
    /// tab, so the URL is routed to the tab manager and nil returned.
    nonisolated func webView(_ webView: WKWebView,
                             createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction,
                             windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url
        Task { @MainActor in
            if let url {
                self.onOpenInNewTab?(url)
            }
        }
        return nil
    }

    // MARK: Context menus (links / images)

    nonisolated func webView(_ webView: WKWebView,
                             contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                             completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        let linkURL = elementInfo.linkURL
        Task { @MainActor in
            completionHandler(self.contextMenuConfiguration(linkURL: linkURL))
        }
    }

    private func contextMenuConfiguration(linkURL: URL?) -> UIContextMenuConfiguration? {
        if let linkURL {
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                UIMenu(title: "", children: self.linkMenuActions(for: linkURL))
            }
        }
        // Images: the element info has no URL, so fall back to the
        // probe's most recent touch report (fresh within 3 seconds).
        if Date().timeIntervalSince(lastTouchAt) < 3,
           let image = lastTouchImage, let imageURL = URL(string: image),
           imageURL.scheme == "http" || imageURL.scheme == "https" {
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                UIMenu(title: "", children: self.imageMenuActions(for: imageURL))
            }
        }
        return nil
    }

    private func linkMenuActions(for url: URL) -> [UIMenuElement] {
        var actions: [UIMenuElement] = [
            UIAction(title: "新しいタブで開く", image: UIImage(systemName: "plus.square.on.square")) { _ in
                Task { @MainActor in self.onOpenInNewTab?(url) }
            },
            UIAction(title: "リンクをコピー", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.url = url
            },
            UIAction(title: "共有…", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                Task { @MainActor in self.shareHandler?([url]) }
            },
            UIAction(title: "このページをスナップ", image: UIImage(systemName: "camera.aperture")) { _ in
                Task { @MainActor in self.snapHandler?() }
            }
        ]
        if PlaylistMedia.isMediaURL(url.absoluteString) {
            actions.append(UIAction(title: "Playlistに追加",
                                    image: UIImage(systemName: "video.badge.plus")) { _ in
                Task { @MainActor in self.playlistLinkHandler?(url.absoluteString) }
            })
        }
        return actions
    }

    private func imageMenuActions(for url: URL) -> [UIMenuElement] {
        [
            UIAction(title: "画像を保存", image: UIImage(systemName: "square.and.arrow.down")) { _ in
                Task { @MainActor in await self.saveImage(at: url) }
            },
            UIAction(title: "画像をコピー", image: UIImage(systemName: "doc.on.doc")) { _ in
                Task { @MainActor in await self.copyImage(at: url) }
            },
            UIAction(title: "新しいタブで開く", image: UIImage(systemName: "plus.square.on.square")) { _ in
                Task { @MainActor in self.onOpenInNewTab?(url) }
            }
        ]
    }

    // MARK: Image save / copy

    /// Downloads the image data (no page cookies, like playlist
    /// downloads) and saves it to the photo library. When photo
    /// access is not granted, the file lands in Documents/Downloads
    /// instead and the notice says so — never a silent failure.
    private func saveImage(at url: URL) async {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              UIImage(data: data) != nil else {
            tabNotice = "画像を取得できませんでした"
            return
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        if status == .authorized || status == .limited {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: data, options: nil)
                }
                tabNotice = "画像を写真に保存しました"
            } catch {
                saveImageDataToDownloads(data, url: url)
            }
        } else {
            saveImageDataToDownloads(data, url: url)
        }
    }

    private func saveImageDataToDownloads(_ data: Data, url: URL) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = url.lastPathComponent.isEmpty ? "image" : url.lastPathComponent
        let destination = folder.appendingPathComponent(name)
        do {
            try data.write(to: destination, options: .atomic)
            tabNotice = "写真へのアクセスがないため、ダウンロードに保存しました"
        } catch {
            tabNotice = "画像の保存に失敗しました"
        }
    }

    private func copyImage(at url: URL) async {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else {
            tabNotice = "画像を取得できませんでした"
            return
        }
        UIPasteboard.general.image = image
        tabNotice = "画像をコピーしました"
    }
}

// MARK: - Media probe messages (v0.4.6) + blob downloads (v0.4.10)

extension BrowserTab {
    /// Native end of the blob: bridge (see blobDownloadScript). The
    /// store writes chunks straight to a staging file, so a large
    /// blob never sits in memory on either side of the bridge.
    func handleBlobMessage(_ body: [String: Any]) {
        guard let store = downloadStore else { return }
        switch body["type"] as? String ?? "" {
        case "start":
            guard let bridgeID = body["id"] as? String else { return }
            let rawName = (body["name"] as? String) ?? ""
            let name = rawName.isEmpty ? "download" : rawName
            let size = (body["size"] as? NSNumber)?.int64Value
            let itemID = store.beginManualDownload(fileName: name,
                                                   sourceURL: currentURLString,
                                                   totalBytes: size)
            blobTransfers[bridgeID] = itemID
        case "chunk":
            guard let bridgeID = body["id"] as? String,
                  let itemID = blobTransfers[bridgeID],
                  let base64 = body["data"] as? String,
                  let data = Data(base64Encoded: base64) else { return }
            store.appendManualChunk(id: itemID, data: data)
        case "end":
            guard let bridgeID = body["id"] as? String,
                  let itemID = blobTransfers.removeValue(forKey: bridgeID) else { return }
            store.finishManualDownload(id: itemID)
        case "error":
            if let bridgeID = body["id"] as? String,
               let itemID = blobTransfers.removeValue(forKey: bridgeID) {
                store.failManualDownload(id: itemID,
                                         message: "ページからの読み取りに失敗しました")
            } else {
                tabNotice = "ダウンロードに失敗しました"
            }
        case "toobig":
            tabNotice = "ファイルが大きすぎて保存できませんでした（上限は100MBです）"
        default:
            break
        }
    }
}

extension BrowserTab: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        if message.name == Self.blobMessageName {
            guard let body = message.body as? [String: Any] else { return }
            Task { @MainActor in self.handleBlobMessage(body) }
            return
        }
        guard message.name == Self.mediaMessageName,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "longpress":
            let url = body["url"] as? String ?? ""
            let streams = body["streams"] as? [String] ?? []
            let frame = message.frameInfo
            Task { @MainActor in
                self.handleVideoLongPress(url: url, title: self.pageTitle,
                                          frame: frame, streams: streams)
            }
        case "plstart", "plchunk", "plend", "plerror":
            Task { @MainActor in
                self.handlePlaylistBlobMessage(body)
            }
        case "changed":
            Task { @MainActor in
                self.scheduleProbeRefresh()
            }
        case "touchinfo":
            let link = body["link"] as? String ?? ""
            let image = body["image"] as? String ?? ""
            Task { @MainActor in
                self.lastTouchLink = link.isEmpty ? nil : link
                self.lastTouchImage = image.isEmpty ? nil : image
                self.lastTouchAt = Date()
            }
        default:
            break
        }
    }
}

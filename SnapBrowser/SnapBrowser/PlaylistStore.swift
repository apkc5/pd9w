import Foundation
import AVFoundation
import UIKit

/// One media candidate detected on a page (from BrowserTab's probe /
/// collect scripts). `url` is absolute; blob: entries are carried so
/// the UI can say honestly that they cannot be saved.
struct DetectedMedia: Identifiable, Equatable {
    let url: String
    var id: String { url }
    var isBlob: Bool { url.lowercased().hasPrefix("blob:") }
    var isHTTP: Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }
    /// An HLS stream URL (downloaded by assembling its segments,
    /// v0.4.14 — see HLSDownloader).
    var isM3U8: Bool {
        guard isHTTP, let parsed = URL(string: url) else { return false }
        return parsed.pathExtension.lowercased() == "m3u8"
    }
}

/// Shared media-URL helpers (menu add / bookmark integration / titles).
enum PlaylistMedia {
    static let fileExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]

    /// True when the URL itself points at a media file (by extension).
    static func isMediaURL(_ string: String) -> Bool {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        return fileExtensions.contains(url.pathExtension.lowercased())
    }

    /// Fallback title for URL-list imports: the last path component
    /// (percent-decoded), or the host when there is no file name.
    static func defaultTitle(for urlString: String) -> String {
        if let url = URL(string: urlString) {
            let last = url.lastPathComponent.removingPercentEncoding
                ?? url.lastPathComponent
            if !last.isEmpty, last != "/" { return last }
            if let host = url.host, !host.isEmpty { return host }
        }
        return urlString
    }
}

struct PlaylistItem: Identifiable, Codable, Equatable {
    enum State: String, Codable {
        case notDownloaded, downloading, downloaded, failed
    }
    var id: UUID
    var title: String
    var url: String
    var pageURL: String?
    var addedAt: Date
    var state: State
    var localFileName: String?
    var thumbnailFileName: String?
    var fileBytes: Int64?
    var errorMessage: String?
    /// How the downloaded payload is stored (v0.4.14): nil for a
    /// plain single file; "hls-ts" when localFileName points at a
    /// playlist.m3u8 inside a per-item folder of TS segments.
    var streamKind: String?
}

/// Playlist (v0.4.6, ported from the Android version): a shelf of
/// media URLs with per-item offline downloads and AVPlayer playback.
///
/// Storage: Documents/playlist.json for the item list and
/// Documents/Playlist/ for downloaded files + thumbnails. Files and
/// UserDefaults only — no Keychain (project rule). The Settings
/// clear-data actions never touch this directory: they clear history
/// and WKWebsiteDataStore only, and this store lives in Documents.
///
/// Downloads carry the page's cookies / UA / Referer (v0.4.14,
/// via requestContextProvider), so login-walled media has its
/// real chance; failures are kept as an explicit failed state on
/// the item (with the HTTP status when there is one), never
/// silently dropped.
final class PlaylistStore: NSObject, ObservableObject {
    @Published private(set) var items: [PlaylistItem] = []
    /// Transient per-item download progress: 0...1, or -1 when the
    /// server gives no total size. Not persisted.
    @Published private(set) var progress: [UUID: Double] = [:]

    private let fileManager = FileManager.default
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private let tasksLock = NSLock()

    private lazy var session: URLSession = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: .default, delegate: self,
                          delegateQueue: queue)
    }()

    /// Extra headers for media requests (v0.4.14): BrowserModel
    /// installs a provider that reads the ACTIVE tab's cookie
    /// store + user agent, so downloads go out the way the page
    /// itself would fetch — the fix for the structural 403s the
    /// plain-URLSession version produced on login-walled or
    /// hotlink-protected media (research §6.2).
    var requestContextProvider: ((URL) async -> [String: String])?

    /// In-flight HLS assembly tasks (v0.4.14), keyed by item id.
    private var hlsTasks: [UUID: Task<Void, Never>] = [:]

    /// In-flight blob: transfers (v0.4.14): bytes stream in from
    /// the page into a staging file, like DownloadStore's manual
    /// transfers, so memory stays flat at any size.
    private var blobStaging: [UUID: BlobStaging] = [:]

    struct BlobStaging {
        var stagingURL: URL
        var handle: FileHandle
        var received: Int64
        var expected: Int64?
        var fileName: String
    }

    /// A request for `url` carrying the provider's headers plus
    /// the item's page as Referer.
    func makeRequest(for url: URL, pageURL: String?) async -> URLRequest {
        var request = URLRequest(url: url)
        if let provider = requestContextProvider {
            for (field, value) in await provider(url) {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        if let pageURL, !pageURL.isEmpty {
            request.setValue(pageURL, forHTTPHeaderField: "Referer")
        }
        return request
    }

    var directoryURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Playlist", isDirectory: true)
    }

    private var indexURL: URL { directoryURL.appendingPathComponent("playlist.json") }

    override init() {
        super.init()
        load()
    }

    // MARK: - Persistence

    private func load() {
        // Leftover blob staging files from a killed session can
        // never be resumed; clear them out.
        if let names = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) {
            for name in names where name.hasPrefix(".partial-") {
                try? fileManager.removeItem(at: directoryURL.appendingPathComponent(name))
            }
        }
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder.snapshotDecoder.decode([PlaylistItem].self, from: data)
        else {
            items = []
            return
        }
        // Sanitise after a relaunch: an in-flight download died with
        // the process, and a "downloaded" item whose file vanished
        // falls back to not-downloaded rather than lying about it.
        items = decoded.map { item in
            var item = item
            if item.state == .downloading {
                item.state = .notDownloaded
            }
            if item.state == .downloaded {
                if let name = item.localFileName,
                   fileManager.fileExists(atPath: directoryURL.appendingPathComponent(name).path) {
                    // still good
                } else {
                    item.state = .notDownloaded
                    item.localFileName = nil
                    item.fileBytes = nil
                }
            }
            return item
        }
    }

    private func persist() {
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.snapshotEncoder.encode(items) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    // MARK: - Adding

    func contains(url: String) -> Bool {
        items.contains { $0.url == url }
    }

    /// Adds one item. Returns false when the URL is already in the
    /// playlist (same no-silent-merge convention as bookmarks).
    @discardableResult
    func add(title: String, url: String, pageURL: String?) -> Bool {
        guard !contains(url: url) else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = PlaylistItem(
            id: UUID(),
            title: trimmed.isEmpty ? PlaylistMedia.defaultTitle(for: url) : trimmed,
            url: url,
            pageURL: pageURL,
            addedAt: Date(),
            state: .notDownloaded,
            localFileName: nil,
            thumbnailFileName: nil,
            fileBytes: nil,
            errorMessage: nil,
            streamKind: nil)
        items.insert(item, at: 0)
        persist()
        return true
    }

    struct ListImportOutcome {
        var added: Int
        var duplicates: Int
        var invalid: Int
    }

    /// Bulk import from a pasted URL list (one URL per line). Only
    /// http(s) lines count as URLs; duplicates against the existing
    /// playlist (and within the paste) are reported, not merged.
    func addFromList(_ text: String) -> ListImportOutcome {
        var outcome = ListImportOutcome(added: 0, duplicates: 0, invalid: 0)
        var seen = Set(items.map { $0.url })
        var newItems: [PlaylistItem] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            guard let url = URL(string: line),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil else {
                outcome.invalid += 1
                continue
            }
            if seen.contains(line) {
                outcome.duplicates += 1
                continue
            }
            seen.insert(line)
            newItems.append(PlaylistItem(
                id: UUID(),
                title: PlaylistMedia.defaultTitle(for: line),
                url: line,
                pageURL: nil,
                addedAt: Date(),
                state: .notDownloaded,
                localFileName: nil,
                thumbnailFileName: nil,
                fileBytes: nil,
                errorMessage: nil,
                streamKind: nil))
            outcome.added += 1
        }
        if !newItems.isEmpty {
            items = newItems.reversed() + items
            persist()
        }
        return outcome
    }

    // MARK: - Removal

    /// Deletes an item's downloaded payload. An "hls-ts" item's
    /// localFileName is "<id>/playlist.m3u8" — the whole segment
    /// folder goes, not just the playlist file.
    private func removeLocalFiles(for item: PlaylistItem) {
        if item.streamKind == "hls-ts" {
            try? fileManager.removeItem(
                at: directoryURL.appendingPathComponent(item.id.uuidString,
                                                         isDirectory: true))
        } else if let name = item.localFileName {
            try? fileManager.removeItem(at: directoryURL.appendingPathComponent(name))
        }
        if let thumb = item.thumbnailFileName {
            try? fileManager.removeItem(at: directoryURL.appendingPathComponent(thumb))
        }
    }

    func remove(_ item: PlaylistItem) {
        cancelDownload(item)
        removeLocalFiles(for: item)
        items.removeAll { $0.id == item.id }
        progress[item.id] = nil
        persist()
    }

    /// Removes every downloaded file (items stay, back to
    /// not-downloaded). This is the ONLY bulk wipe for playlist
    /// files — Settings' browsing-data clearing does not touch them.
    func deleteAllDownloads() {
        for item in items where item.state == .downloading {
            cancelDownload(item)
        }
        for index in items.indices {
            removeLocalFiles(for: items[index])
            items[index].localFileName = nil
            items[index].streamKind = nil
            items[index].thumbnailFileName = nil
            items[index].fileBytes = nil
            items[index].errorMessage = nil
            if items[index].state == .downloaded || items[index].state == .downloading {
                items[index].state = .notDownloaded
            }
        }
        progress = [:]
        persist()
    }

    // MARK: - ZIP export (v0.4.9)

    struct ZipExportResult {
        var url: URL
        var count: Int
        var totalBytes: Int64
    }

    /// Packages every downloaded file into ONE zip in the caches
    /// directory (temporary by design — the caller deletes it after
    /// the share sheet finishes). Entries are stored uncompressed
    /// and streamed, so large libraries never load into memory.
    /// Non-downloaded items are excluded. Entry names are
    /// "01_<title>.<ext>", sanitised and de-duplicated.
    func exportDownloadedAsZip() async throws -> ZipExportResult? {
        let downloaded = items.filter { $0.state == .downloaded }
        var sources: [(file: URL, name: String)] = []
        var usedNames = Set<String>()
        for (index, item) in downloaded.enumerated() {
            guard let file = localFileURL(for: item) else { continue }
            let ext = file.pathExtension.isEmpty ? "mp4" : file.pathExtension
            var base = item.title
                .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
                .joined(separator: "_")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty { base = "video" }
            if item.streamKind == "hls-ts" {
                // The item is a folder of segments + playlist:
                // export every file under one folder entry name.
                var folderName = String(format: "%02d_%@", index + 1, base)
                var counter = 2
                while usedNames.contains(folderName) {
                    folderName = String(format: "%02d_%@ (%d)", index + 1, base, counter)
                    counter += 1
                }
                usedNames.insert(folderName)
                let folder = file.deletingLastPathComponent()
                let entries = (try? fileManager.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: nil)) ?? []
                for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    sources.append((entry, "\(folderName)/\(entry.lastPathComponent)"))
                }
                continue
            }
            var name = String(format: "%02d_%@.%@", index + 1, base, ext)
            var counter = 2
            while usedNames.contains(name) {
                name = String(format: "%02d_%@ (%d).%@", index + 1, base, counter, ext)
                counter += 1
            }
            usedNames.insert(name)
            sources.append((file, name))
        }
        guard !sources.isEmpty else { return nil }

        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = caches.appendingPathComponent("PlaylistExport", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let zipURL = folder.appendingPathComponent("playlist-\(stamp.string(from: Date())).zip")
        let totalBytes = sources.reduce(Int64(0)) { sum, source in
            sum + ((try? fileManager.attributesOfItem(atPath: source.file.path)[.size]) as? Int64 ?? 0)
        }
        // The writer does blocking file IO; keep it off the main actor.
        let writer = try ZipWriter(outputURL: zipURL)
        for source in sources {
            try writer.addFile(at: source.file, archiveName: source.name)
        }
        try writer.finish()
        return ZipExportResult(url: zipURL, count: sources.count, totalBytes: totalBytes)
    }

    var totalDownloadedBytes: Int64 {
        items.reduce(0) { $0 + ($1.fileBytes ?? 0) }
    }

    var downloadedCount: Int {
        items.filter { $0.state == .downloaded }.count
    }

    // MARK: - File URLs / playback

    func localFileURL(for item: PlaylistItem) -> URL? {
        guard item.state == .downloaded, let name = item.localFileName else { return nil }
        let url = directoryURL.appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func thumbnailURL(for item: PlaylistItem) -> URL? {
        guard let name = item.thumbnailFileName else { return nil }
        let url = directoryURL.appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// What AVPlayer should open: the local file when downloaded,
    /// otherwise the remote URL (streaming).
    func playbackURL(for item: PlaylistItem) -> URL? {
        if let local = localFileURL(for: item) { return local }
        return URL(string: item.url)
    }

    // MARK: - Downloads

    func startDownload(_ item: PlaylistItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard items[index].state != .downloading else { return }
        guard let url = URL(string: items[index].url) else {
            items[index].state = .failed
            items[index].errorMessage = "URLが不正です"
            persist()
            return
        }
        items[index].state = .downloading
        items[index].errorMessage = nil
        progress[item.id] = 0
        persist()

        let itemID = item.id
        let pageURL = items[index].pageURL
        // HLS streams are assembled from their segments instead of
        // downloaded as one file (v0.4.14 — HLSDownloader).
        if url.pathExtension.lowercased() == "m3u8" {
            startHLSDownload(itemID: itemID, url: url, pageURL: pageURL)
            return
        }
        // The request is built asynchronously (cookies come from
        // the WebView's store); the task is created on the main
        // queue afterwards, and only if the item is still meant
        // to be downloading (the user may have cancelled).
        Task { [weak self] in
            guard let self else { return }
            let request = await self.makeRequest(for: url, pageURL: pageURL)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.items.first(where: { $0.id == itemID })?.state == .downloading
                else { return }
                let task = self.session.downloadTask(with: request)
                task.taskDescription = itemID.uuidString
                self.tasksLock.lock()
                self.tasks[itemID] = task
                self.tasksLock.unlock()
                task.resume()
            }
        }
    }

    // MARK: - HLS downloads (v0.4.14)

    private func startHLSDownload(itemID: UUID, url: URL, pageURL: String?) {
        let downloader = HLSDownloader(makeRequest: { [weak self] segmentURL in
            await self?.makeRequest(for: segmentURL, pageURL: pageURL)
                ?? URLRequest(url: segmentURL)
        })
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await downloader.download(from: url) { done, total in
                    DispatchQueue.main.async { [weak self] in
                        self?.progress[itemID] = total > 0
                            ? Double(done) / Double(total) : -1
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    self?.finishHLSDownload(itemID: itemID, output: output)
                }
            } catch is CancellationError {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.hlsTasks[itemID] = nil
                    self.progress[itemID] = nil
                    self.updateItem(itemID) {
                        if $0.state == .downloading { $0.state = .notDownloaded }
                    }
                }
            } catch let failure as HLSDownloadFailure {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.hlsTasks[itemID] = nil
                    self.progress[itemID] = nil
                    self.updateItem(itemID) {
                        $0.state = .failed
                        $0.errorMessage = failure.message
                    }
                }
            } catch {
                let cancelled = Task.isCancelled
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.hlsTasks[itemID] = nil
                    self.progress[itemID] = nil
                    self.updateItem(itemID) {
                        if cancelled {
                            if $0.state == .downloading { $0.state = .notDownloaded }
                        } else {
                            $0.state = .failed
                            $0.errorMessage = message
                        }
                    }
                }
            }
        }
        hlsTasks[itemID] = task
    }

    /// Moves an assembled HLS output (single .mp4, or a segment
    /// folder + local playlist) into the Playlist directory.
    private func finishHLSDownload(itemID: UUID, output: HLSDownloadOutput) {
        hlsTasks[itemID] = nil
        progress[itemID] = nil
        guard items.contains(where: { $0.id == itemID }) else {
            try? fileManager.removeItem(at: output.url)
            return
        }
        do {
            try fileManager.createDirectory(at: directoryURL,
                                            withIntermediateDirectories: true)
            if output.isFolder {
                let folderName = itemID.uuidString
                let dest = directoryURL.appendingPathComponent(folderName,
                                                               isDirectory: true)
                if fileManager.fileExists(atPath: dest.path) {
                    try fileManager.removeItem(at: dest)
                }
                try fileManager.moveItem(at: output.url, to: dest)
                updateItem(itemID) {
                    $0.state = .downloaded
                    $0.localFileName = "\(folderName)/playlist.m3u8"
                    $0.streamKind = "hls-ts"
                    $0.fileBytes = output.totalBytes
                    $0.errorMessage = nil
                }
                generateThumbnail(itemID: itemID,
                                  fileURL: dest.appendingPathComponent("playlist.m3u8"))
            } else {
                let fileName = "\(itemID.uuidString).mp4"
                let dest = directoryURL.appendingPathComponent(fileName)
                if fileManager.fileExists(atPath: dest.path) {
                    try fileManager.removeItem(at: dest)
                }
                try fileManager.moveItem(at: output.url, to: dest)
                updateItem(itemID) {
                    $0.state = .downloaded
                    $0.localFileName = fileName
                    $0.streamKind = nil
                    $0.fileBytes = output.totalBytes
                    $0.errorMessage = nil
                }
                generateThumbnail(itemID: itemID, fileURL: dest)
            }
        } catch {
            try? fileManager.removeItem(at: output.url)
            updateItem(itemID) {
                $0.state = .failed
                $0.errorMessage = "保存に失敗: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Blob transfers (v0.4.14)

    /// Creates an item whose bytes stream in from the page itself
    /// (a plain Blob, classified as such in BrowserTab) — the
    /// staging-file pattern from DownloadStore, so memory stays
    /// flat. No size cap: the user's standing call is unlimited.
    @discardableResult
    func beginBlobItem(title: String, url: String, pageURL: String?,
                       fileName: String, expectedBytes: Int64?) -> UUID {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = PlaylistItem(
            id: UUID(),
            title: trimmed.isEmpty ? PlaylistMedia.defaultTitle(for: url) : trimmed,
            url: url,
            pageURL: pageURL,
            addedAt: Date(),
            state: .downloading,
            localFileName: nil,
            thumbnailFileName: nil,
            fileBytes: nil,
            errorMessage: nil,
            streamKind: nil)
        items.insert(item, at: 0)
        progress[item.id] = 0
        persist()
        do {
            try fileManager.createDirectory(at: directoryURL,
                                            withIntermediateDirectories: true)
            let staging = directoryURL.appendingPathComponent(".partial-\(item.id.uuidString)")
            fileManager.createFile(atPath: staging.path, contents: nil)
            let handle = try FileHandle(forWritingTo: staging)
            blobStaging[item.id] = BlobStaging(stagingURL: staging,
                                               handle: handle,
                                               received: 0,
                                               expected: expectedBytes,
                                               fileName: fileName)
        } catch {
            failBlobItem(itemID: item.id, message: "保存を開始できませんでした")
        }
        return item.id
    }

    func appendBlobChunk(itemID: UUID, data: Data) {
        guard var staging = blobStaging[itemID] else { return }
        do {
            try staging.handle.write(contentsOf: data)
        } catch {
            failBlobItem(itemID: itemID, message: "書き込みに失敗しました")
            return
        }
        staging.received += Int64(data.count)
        blobStaging[itemID] = staging
        if let expected = staging.expected, expected > 0 {
            progress[itemID] = Double(staging.received) / Double(expected)
        }
    }

    func finishBlobItem(itemID: UUID) {
        guard let staging = blobStaging.removeValue(forKey: itemID) else { return }
        try? staging.handle.close()
        let ext = (staging.fileName as NSString).pathExtension.lowercased()
        let finalName = "\(itemID.uuidString).\(ext.isEmpty ? "mp4" : ext)"
        let dest = directoryURL.appendingPathComponent(finalName)
        do {
            if fileManager.fileExists(atPath: dest.path) {
                try fileManager.removeItem(at: dest)
            }
            try fileManager.moveItem(at: staging.stagingURL, to: dest)
        } catch {
            updateItem(itemID) {
                $0.state = .failed
                $0.errorMessage = "保存に失敗しました"
            }
            progress[itemID] = nil
            return
        }
        progress[itemID] = nil
        updateItem(itemID) {
            $0.state = .downloaded
            $0.localFileName = finalName
            $0.fileBytes = staging.received
            $0.errorMessage = nil
        }
        generateThumbnail(itemID: itemID, fileURL: dest)
    }

    func failBlobItem(itemID: UUID, message: String) {
        if let staging = blobStaging.removeValue(forKey: itemID) {
            try? staging.handle.close()
            try? fileManager.removeItem(at: staging.stagingURL)
        }
        progress[itemID] = nil
        updateItem(itemID) {
            if $0.state == .downloading {
                $0.state = .failed
                $0.errorMessage = message
            }
        }
    }

    func cancelDownload(_ item: PlaylistItem) {
        tasksLock.lock()
        let task = tasks[item.id]
        tasks[item.id] = nil
        tasksLock.unlock()
        task?.cancel()
        if let hls = hlsTasks.removeValue(forKey: item.id) {
            hls.cancel()
        }
        if let staging = blobStaging.removeValue(forKey: item.id) {
            try? staging.handle.close()
            try? fileManager.removeItem(at: staging.stagingURL)
        }
        if let index = items.firstIndex(where: { $0.id == item.id }),
           items[index].state == .downloading {
            items[index].state = .notDownloaded
            progress[item.id] = nil
            persist()
        }
    }

    private func updateItem(_ id: UUID, _ change: (inout PlaylistItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        persist()
    }

    // MARK: - Thumbnail

    /// Grabs a frame (~1s in) from a downloaded file with
    /// AVAssetImageGenerator and stores it next to the media file.
    private func generateThumbnail(itemID: UUID, fileURL: URL) {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        let time = CMTime(seconds: 1.0, preferredTimescale: 600)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
            [weak self] _, cgImage, _, result, _ in
            guard let self, result == .succeeded, let cgImage else { return }
            let name = "\(itemID.uuidString).jpg"
            let dest = self.directoryURL.appendingPathComponent(name)
            if let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.7) {
                try? data.write(to: dest, options: .atomic)
            }
            DispatchQueue.main.async {
                self.updateItem(itemID) { $0.thumbnailFileName = name }
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension PlaylistStore: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let idString = downloadTask.taskDescription,
              let id = UUID(uuidString: idString) else { return }
        // An HTTP error status means the "file" is an error page:
        // fail with the status in the reason instead of saving it
        // as if it were media (v0.4.14).
        if let http = downloadTask.response as? HTTPURLResponse,
           http.statusCode >= 400 {
            let message = http.statusCode == 403
                ? "保存に失敗しました（HTTP 403：アクセスが拒否されました。要ログインの可能性）"
                : "保存に失敗しました（HTTP \(http.statusCode)）"
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.progress[id] = nil
                self.updateItem(id) {
                    $0.state = .failed
                    $0.errorMessage = message
                }
            }
            return
        }
        // The temp file is deleted when this callback returns, so the
        // move happens here, synchronously, on the delegate queue.
        let ext: String = {
            let e = downloadTask.response?.url?.pathExtension.lowercased() ?? ""
            return PlaylistMedia.fileExtensions.contains(e) ? e : "mp4"
        }()
        let fileName = "\(id.uuidString).\(ext)"
        let dest = directoryURL.appendingPathComponent(fileName)
        var movedBytes: Int64?
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: dest.path) {
                try fileManager.removeItem(at: dest)
            }
            try fileManager.moveItem(at: location, to: dest)
            movedBytes = (try? fileManager.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? nil
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.progress[id] = nil
                self.updateItem(id) {
                    $0.state = .failed
                    $0.errorMessage = "保存に失敗: \(message)"
                }
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.progress[id] = nil
            self.updateItem(id) {
                $0.state = .downloaded
                $0.localFileName = fileName
                $0.fileBytes = movedBytes
                $0.errorMessage = nil
            }
            self.generateThumbnail(itemID: id, fileURL: dest)
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let idString = downloadTask.taskDescription,
              let id = UUID(uuidString: idString) else { return }
        let value = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : -1
        DispatchQueue.main.async { [weak self] in
            self?.progress[id] = value
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let idString = task.taskDescription,
              let id = UUID(uuidString: idString) else { return }
        tasksLock.lock()
        tasks[id] = nil
        tasksLock.unlock()
        guard let error else { return } // success path handled in didFinishDownloadingTo
        let nsError = error as NSError
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.progress[id] = nil
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                self.updateItem(id) {
                    if $0.state == .downloading { $0.state = .notDownloaded }
                }
            } else {
                self.updateItem(id) {
                    $0.state = .failed
                    $0.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

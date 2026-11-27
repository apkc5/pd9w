import Foundation
import SwiftUI
import WebKit

/// One file download (v0.4.9): started by WKWebView when a navigation
/// turns into a download (attachment responses, non-displayable
/// types, `download` links). Files land in Documents/Downloads/;
/// the item list persists in Documents/downloads.json so finished
/// downloads survive relaunches. In-flight ones cannot resume after
/// a relaunch (WKDownload dies with the process) and are honestly
/// marked failed/interrupted instead of pretending.
struct DownloadItem: Identifiable, Codable, Equatable {
    enum State: String, Codable {
        case downloading, completed, failed
    }
    var id: UUID
    var fileName: String
    var sourceURL: String?
    var state: State
    var totalBytes: Int64?
    var errorMessage: String?
    var createdAt: Date
}

final class DownloadStore: NSObject, ObservableObject {
    @Published private(set) var items: [DownloadItem] = []
    /// Transient progress fractions (0...1) per item, not persisted.
    @Published private(set) var progress: [UUID: Double] = [:]

    /// User-visible lifecycle notices (v0.4.10): start / completion /
    /// failure. Until v0.4.9 a download ran completely silently —
    /// nothing on screen changed when one started or finished, so a
    /// working download still read as 「できない」. BrowserModel
    /// forwards these to the toast.
    var onNotice: ((String) -> Void)?

    private let fileManager = FileManager.default
    private var progressObservations: [UUID: NSKeyValueObservation] = [:]

    /// In-flight manual (blob:) transfers, keyed by item id.
    var manualTransfers: [UUID: ManualTransfer] = [:]

    struct ManualTransfer {
        var stagingURL: URL
        var handle: FileHandle
        var received: Int64
        var expected: Int64?
    }

    var directoryURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Downloads", isDirectory: true)
    }

    private var indexURL: URL { directoryURL.appendingPathComponent("downloads.json") }

    override init() {
        super.init()
        load()
    }

    private func load() {
        // Leftover blob-bridge staging files from a killed session
        // can never be resumed; clear them out.
        if let names = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) {
            for name in names where name.hasPrefix(".partial-") {
                try? fileManager.removeItem(at: directoryURL.appendingPathComponent(name))
            }
        }
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder.snapshotDecoder.decode([DownloadItem].self, from: data)
        else { return }
        // Same sanitising rule as the playlist: a "downloading" item
        // after a relaunch was interrupted; a "completed" item whose
        // file vanished is not completed any more.
        items = decoded.map { item in
            var item = item
            if item.state == .downloading {
                item.state = .failed
                item.errorMessage = "アプリ終了により中断されました"
            }
            if item.state == .completed,
               !fileManager.fileExists(atPath: directoryURL.appendingPathComponent(item.fileName).path) {
                item.state = .failed
                item.errorMessage = "ファイルが見つかりません"
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

    /// Takes ownership of a WKDownload handed over by a tab.
    /// (This SDK's WKDownload exposes no `response` — the suggested
    /// filename only arrives via the delegate's destination call,
    /// which renames the item there.)
    func attach(_ download: WKDownload) {
        let item = DownloadItem(
            id: UUID(),
            fileName: download.originalRequest?.url?.lastPathComponent ?? "download",
            sourceURL: download.originalRequest?.url?.absoluteString,
            state: .downloading,
            totalBytes: nil,
            errorMessage: nil,
            createdAt: Date())
        items.insert(item, at: 0)
        persist()
        onNotice?("ダウンロードを開始しました：\(item.fileName)")
        download.delegate = self
        // WKDownload exposes a Foundation Progress; observe it for
        // the list UI (fraction + total unit count).
        let id = item.id
        progressObservations[id] = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let total = progress.totalUnitCount
            DispatchQueue.main.async {
                guard let self else { return }
                self.progress[id] = progress.fractionCompleted
                if total > 0, let index = self.items.firstIndex(where: { $0.id == id }),
                   self.items[index].totalBytes != total {
                    self.items[index].totalBytes = total
                }
            }
        }
    }

    func fileURL(for item: DownloadItem) -> URL? {
        let url = directoryURL.appendingPathComponent(item.fileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func remove(_ item: DownloadItem) {
        if let url = fileURL(for: item) {
            try? fileManager.removeItem(at: url)
        }
        items.removeAll { $0.id == item.id }
        progress[item.id] = nil
        progressObservations[item.id] = nil
        persist()
    }

    private func update(fileName: String, _ change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.fileName == fileName }) else { return }
        change(&items[index])
        persist()
    }
}

// MARK: - WKDownloadDelegate

extension DownloadStore: WKDownloadDelegate {
    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            completionHandler(nil)
            return
        }
        // De-duplicate the destination name the way desktop browsers
        // do: name.ext, name 2.ext, name 3.ext …
        let candidate = uniqueFileName(suggestedFilename)
        let destination = directoryURL.appendingPathComponent(candidate)
        // The item created in attach() carries the request's file
        // name; align it with the (possibly de-duplicated)
        // destination so the list and the file system agree. Match
        // by source URL first, then by the suggested name.
        let source = response.url?.absoluteString
        if let index = items.firstIndex(where: {
            $0.state == .downloading && ($0.sourceURL == source || $0.fileName == suggestedFilename)
        }) {
            items[index].fileName = candidate
            persist()
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        // Match the downloading item for this download's source URL.
        let source = download.originalRequest?.url?.absoluteString
        if let index = items.firstIndex(where: {
            $0.state == .downloading && $0.sourceURL == source
        }) {
            let item = items[index]
            items[index].state = .completed
            if let url = fileURL(for: item),
               let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size]) as? Int64 {
                items[index].totalBytes = size
            }
            progress[item.id] = nil
            progressObservations[item.id] = nil
            persist()
            onNotice?("ダウンロードが完了しました：\(item.fileName)")
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error,
                  resumeData: Data?) {
        let source = download.originalRequest?.url?.absoluteString
        if let index = items.firstIndex(where: {
            $0.state == .downloading && $0.sourceURL == source
        }) {
            let item = items[index]
            items[index].state = .failed
            items[index].errorMessage = error.localizedDescription
            progress[item.id] = nil
            progressObservations[item.id] = nil
            persist()
            onNotice?("ダウンロードに失敗しました：\(item.fileName)")
        }
    }
}

// MARK: - Manual downloads (blob: bridge, v0.4.10)

extension DownloadStore {
    /// name.ext → name 2.ext → name 3.ext … (shared by WKDownload
    /// destinations and manual downloads).
    private func uniqueFileName(_ suggested: String) -> String {
        var candidate = suggested
        var counter = 2
        while fileManager.fileExists(atPath: directoryURL.appendingPathComponent(candidate).path) {
            let ns = suggested as NSString
            let ext = ns.pathExtension
            let base = ns.deletingPathExtension
            candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    /// Starts a download whose bytes arrive from the page itself
    /// (the blob: bridge in BrowserTab). Chunks are appended to a
    /// staging file, so memory stays flat at any file size.
    func beginManualDownload(fileName: String, sourceURL: String?, totalBytes: Int64?) -> UUID {
        // The name comes from the page (a download attribute); never
        // let it carry path components.
        let safeName = (fileName as NSString).lastPathComponent
        let item = DownloadItem(
            id: UUID(),
            fileName: safeName.isEmpty ? "download" : safeName,
            sourceURL: sourceURL,
            state: .downloading,
            totalBytes: totalBytes,
            errorMessage: nil,
            createdAt: Date())
        items.insert(item, at: 0)
        persist()
        onNotice?("ダウンロードを開始しました：\(item.fileName)")
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let staging = directoryURL.appendingPathComponent(".partial-\(item.id.uuidString)")
            fileManager.createFile(atPath: staging.path, contents: nil)
            let handle = try FileHandle(forWritingTo: staging)
            manualTransfers[item.id] = ManualTransfer(stagingURL: staging,
                                                      handle: handle,
                                                      received: 0,
                                                      expected: totalBytes)
        } catch {
            failManualDownload(id: item.id, message: "保存を開始できませんでした")
        }
        return item.id
    }

    func appendManualChunk(id: UUID, data: Data) {
        guard var transfer = manualTransfers[id] else { return }
        do {
            try transfer.handle.write(contentsOf: data)
        } catch {
            failManualDownload(id: id, message: "書き込みに失敗しました")
            return
        }
        transfer.received += Int64(data.count)
        manualTransfers[id] = transfer
        if let expected = transfer.expected, expected > 0 {
            progress[id] = Double(transfer.received) / Double(expected)
        }
    }

    func finishManualDownload(id: UUID) {
        guard let transfer = manualTransfers.removeValue(forKey: id) else { return }
        try? transfer.handle.close()
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            try? fileManager.removeItem(at: transfer.stagingURL)
            return
        }
        let finalName = uniqueFileName(items[index].fileName)
        do {
            try fileManager.moveItem(at: transfer.stagingURL,
                                     to: directoryURL.appendingPathComponent(finalName))
            items[index].fileName = finalName
            items[index].state = .completed
            items[index].totalBytes = transfer.received
            progress[id] = nil
            persist()
            onNotice?("ダウンロードが完了しました：\(finalName)")
        } catch {
            items[index].state = .failed
            items[index].errorMessage = "保存に失敗しました"
            progress[id] = nil
            persist()
            onNotice?("ダウンロードに失敗しました：\(items[index].fileName)")
        }
    }

    func failManualDownload(id: UUID, message: String) {
        if let transfer = manualTransfers.removeValue(forKey: id) {
            try? transfer.handle.close()
            try? fileManager.removeItem(at: transfer.stagingURL)
        }
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .downloading else { return }
        items[index].state = .failed
        items[index].errorMessage = message
        progress[id] = nil
        persist()
        onNotice?("ダウンロードに失敗しました：\(items[index].fileName)")
    }
}

// MARK: - Downloads list UI (from the ⋯ menu)

struct DownloadsView: View {
    @ObservedObject var store: DownloadStore
    @Environment(\.dismiss) private var dismiss
    @State private var sharePayload: SharePayload?

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("ダウンロードはまだありません")
                            .font(.headline)
                            .foregroundStyle(Theme.ink)
                        Text("ファイルのリンクを開くと、ここに保存されます")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                } else {
                    List {
                        ForEach(store.items) { item in
                            row(for: item)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("ダウンロード")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .sheet(item: $sharePayload) { payload in
                ShareSheet(items: payload.items)
            }
        }
    }

    private func row(for item: DownloadItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: item))
                .font(.title3)
                .foregroundStyle(Theme.cobalt)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                stateLine(for: item)
            }
            Spacer(minLength: 0)
            if item.state == .downloading, let value = store.progress[item.id] {
                ProgressView(value: value)
                    .progressViewStyle(.circular)
                    .frame(width: 28, height: 28)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if item.state == .completed, let url = store.fileURL(for: item) {
                sharePayload = SharePayload(items: [url])
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.remove(item)
            } label: {
                Label("削除", systemImage: "trash")
            }
            if item.state == .completed, let url = store.fileURL(for: item) {
                Button {
                    sharePayload = SharePayload(items: [url])
                } label: {
                    Label("共有", systemImage: "square.and.arrow.up")
                }
                .tint(Theme.cobalt)
            }
        }
    }

    private func iconName(for item: DownloadItem) -> String {
        switch item.state {
        case .downloading: return "arrow.down.circle"
        case .completed: return "doc.fill"
        case .failed: return "exclamationmark.circle"
        }
    }

    @ViewBuilder
    private func stateLine(for item: DownloadItem) -> some View {
        switch item.state {
        case .downloading:
            if let value = store.progress[item.id] {
                Text("ダウンロード中 \(Int(value * 100))%")
                    .font(.caption)
                    .foregroundStyle(Theme.cobalt)
            } else {
                Text("ダウンロード中…")
                    .font(.caption)
                    .foregroundStyle(Theme.cobalt)
            }
        case .completed:
            Text("完了 ・ \(ByteCountFormatter.string(fromByteCount: item.totalBytes ?? 0, countStyle: .file))（タップで共有）")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            Text("失敗: \(item.errorMessage ?? "不明なエラー")")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}

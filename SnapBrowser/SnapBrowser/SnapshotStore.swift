import Foundation

/// On-disk snapshot library: Documents/Snapshots/<timestamp>_<id>/
///   image.png          full-page (or viewport) capture
///   archive.webarchive iOS web archive (Apple-only format, ≠ MHTML)
///   page.html          raw HTML source (portable)
///   full.html          self-contained HTML (CSS/images inlined, v0.2+)
///   snapmedia-N.<ext>  bundled direct-file video/audio (v0.4.13,
///                      referenced by relative name from full.html)
///   text.txt           extracted body text
///   meta.json          title / url / createdAt / per-file byte counts
///
/// Files only — no database, no Keychain.
struct SnapshotItem: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var title: String
    var url: String
    var createdAt: Date
    var folderName: String
    var imageBytes: Int?
    var archiveBytes: Int?
    var textChars: Int?
    var htmlBytes: Int?
    var fullHTMLBytes: Int?
    /// Total bytes of bundled media files (v0.4.13). Optional so
    /// meta.json files written by older versions still decode.
    var mediaBytes: Int? = nil
}

final class SnapshotStore: ObservableObject {
    @Published private(set) var items: [SnapshotItem] = []

    private let fileManager = FileManager.default

    var rootURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Snapshots", isDirectory: true)
    }

    init() {
        reload()
    }

    // MARK: - Save

    struct SaveOutcome {
        var imageBytes: Int?
        var archiveBytes: Int?
        var textChars: Int?
        var htmlBytes: Int?
        var fullHTMLBytes: Int?
        var mediaBytes: Int?
        var mediaCount: Int
        var failures: [String]
    }

    /// Writes whichever components were captured. A component is reported as
    /// saved only after its file verifiably exists with non-zero size —
    /// same honesty rule as the Android version (never trust the callback alone).
    func save(title: String,
              url: String,
              imageData: Data?,
              archiveData: Data?,
              text: String?,
              htmlData: Data?,
              fullHTMLData: Data? = nil,
              mediaFiles: [(name: String, tempURL: URL)] = []) throws -> SaveOutcome {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let id = UUID().uuidString
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let folderName = "\(formatter.string(from: Date()))_\(id.prefix(8))"
        let folder = rootURL.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        var outcome = SaveOutcome(imageBytes: nil, archiveBytes: nil,
                                  textChars: nil, htmlBytes: nil,
                                  fullHTMLBytes: nil, mediaBytes: nil,
                                  mediaCount: 0, failures: [])

        func writeVerified(_ data: Data?, _ name: String) -> Int? {
            guard let data, !data.isEmpty else { return nil }
            let dest = folder.appendingPathComponent(name)
            do {
                try data.write(to: dest, options: .atomic)
                let size = (try? fileManager.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? nil
                if let size, size > 0 { return size }
                outcome.failures.append("\(name): 書き込み後にファイルを確認できない")
                return nil
            } catch {
                outcome.failures.append("\(name): \(error.localizedDescription)")
                return nil
            }
        }

        outcome.imageBytes = writeVerified(imageData, "image.png")
        outcome.archiveBytes = writeVerified(archiveData, "archive.webarchive")
        outcome.htmlBytes = writeVerified(htmlData, "page.html")
        outcome.fullHTMLBytes = writeVerified(fullHTMLData, "full.html")
        if let text {
            outcome.textChars = text.count
            _ = writeVerified(Data(text.utf8), "text.txt")
        }

        // Bundled media (v0.4.13 phase 2b): files the archive
        // builder downloaded to temp are MOVED into the folder —
        // never copied through memory, since they are uncapped in
        // size. full.html references them by relative name, which
        // resolves because archives are opened with read access
        // to this whole folder (both open paths audited).
        var mediaBytes = 0
        for media in mediaFiles {
            let dest = folder.appendingPathComponent(media.name)
            do {
                try fileManager.moveItem(at: media.tempURL, to: dest)
                let size = (try? fileManager.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? nil
                if let size, size > 0 {
                    mediaBytes += size
                    outcome.mediaCount += 1
                } else {
                    outcome.failures.append("\(media.name): 書き込み後にファイルを確認できない")
                }
            } catch {
                outcome.failures.append("\(media.name): \(error.localizedDescription)")
            }
        }
        outcome.mediaBytes = outcome.mediaCount > 0 ? mediaBytes : nil

        let item = SnapshotItem(id: id,
                                title: title.isEmpty ? url : title,
                                url: url,
                                createdAt: Date(),
                                folderName: folderName,
                                imageBytes: outcome.imageBytes,
                                archiveBytes: outcome.archiveBytes,
                                textChars: outcome.textChars,
                                htmlBytes: outcome.htmlBytes,
                                fullHTMLBytes: outcome.fullHTMLBytes,
                                mediaBytes: outcome.mediaBytes)
        let meta = try JSONEncoder.snapshotEncoder.encode(item)
        try meta.write(to: folder.appendingPathComponent("meta.json"), options: .atomic)

        reload()
        return outcome
    }

    // MARK: - Load / delete

    func reload() {
        guard let folders = try? fileManager.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil) else {
            items = []
            return
        }
        var loaded: [SnapshotItem] = []
        for folder in folders {
            let metaURL = folder.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let item = try? JSONDecoder.snapshotDecoder.decode(SnapshotItem.self, from: data)
            else { continue }
            loaded.append(item)
        }
        items = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    func delete(_ item: SnapshotItem) {
        try? fileManager.removeItem(at: folderURL(for: item))
        reload()
    }

    func folderURL(for item: SnapshotItem) -> URL {
        rootURL.appendingPathComponent(item.folderName, isDirectory: true)
    }

    func fileURL(for item: SnapshotItem, name: String) -> URL {
        folderURL(for: item).appendingPathComponent(name)
    }

    /// "2026-11-25" style day key for the library's date grouping.
    func dayKey(for item: SnapshotItem) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: item.createdAt)
    }
}

extension JSONEncoder {
    static var snapshotEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var snapshotDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

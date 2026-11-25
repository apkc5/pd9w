import Foundation

/// Bookmarks with a folder hierarchy, mirroring the Android version:
///  - folders form a tree (parentID), bookmarks live in one folder
///  - root-level imports land in the default folder 「モバイルのブックマーク」
///  - empty folders are kept (they are part of the user's organisation)
///  - javascript: bookmarklets are kept, never dropped
/// Persistence: a single JSON file in Documents. No Keychain, no database.
struct BookmarkFolder: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var parentID: UUID?
}

struct Bookmark: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var url: String
    var folderID: UUID?
    var addedAt: Date
}

final class BookmarkStore: ObservableObject {
    @Published private(set) var folders: [BookmarkFolder] = []
    @Published private(set) var bookmarks: [Bookmark] = []

    static let defaultFolderName = "モバイルのブックマーク"

    private struct Persisted: Codable {
        var folders: [BookmarkFolder]
        var bookmarks: [Bookmark]
    }

    private var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("bookmarks.json")
    }

    init() {
        load()
        if folders.isEmpty {
            folders = [BookmarkFolder(id: UUID(), name: Self.defaultFolderName, parentID: nil)]
            save()
        }
    }

    var defaultFolderID: UUID {
        if let existing = folders.first(where: { $0.parentID == nil && $0.name == Self.defaultFolderName }) {
            return existing.id
        }
        let folder = BookmarkFolder(id: UUID(), name: Self.defaultFolderName, parentID: nil)
        folders.append(folder)
        save()
        return folder.id
    }

    // MARK: - Queries

    func subfolders(of parentID: UUID?) -> [BookmarkFolder] {
        folders.filter { $0.parentID == parentID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func bookmarks(in folderID: UUID?) -> [Bookmark] {
        bookmarks.filter { $0.folderID == folderID }
            .sorted { $0.addedAt < $1.addedAt }
    }

    /// Bookmark count in a folder including all descendants (Android parity).
    func count(in folderID: UUID) -> Int {
        var total = bookmarks.count { $0.folderID == folderID }
        for child in folders where child.parentID == folderID {
            total += count(in: child.id)
        }
        return total
    }

    func folderName(for id: UUID?) -> String {
        guard let id else { return "" }
        return folders.first { $0.id == id }?.name ?? ""
    }

    func search(_ query: String) -> [Bookmark] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        return bookmarks.filter {
            $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q)
        }.sorted { $0.addedAt > $1.addedAt }
    }

    // MARK: - Mutations

    @discardableResult
    func createFolder(name: String, parentID: UUID?) -> BookmarkFolder {
        let clean = name.replacingOccurrences(of: "/", with: "／")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = BookmarkFolder(id: UUID(),
                                    name: clean.isEmpty ? "新しいフォルダ" : clean,
                                    parentID: parentID)
        folders.append(folder)
        save()
        return folder
    }

    @discardableResult
    func addBookmark(title: String, url: String, folderID: UUID?) -> Bool {
        guard !url.isEmpty else { return false }
        guard !bookmarks.contains(where: { $0.url == url }) else { return false }
        bookmarks.append(Bookmark(id: UUID(),
                                  title: title.isEmpty ? url : title,
                                  url: url,
                                  folderID: folderID ?? defaultFolderID,
                                  addedAt: Date()))
        save()
        return true
    }

    func deleteBookmark(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        save()
    }

    private func findOrCreateFolder(name: String, parentID: UUID?) -> UUID {
        if let existing = folders.first(where: { $0.parentID == parentID && $0.name == name }) {
            return existing.id
        }
        let folder = BookmarkFolder(id: UUID(), name: name, parentID: parentID)
        folders.append(folder)
        return folder.id
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        folders = decoded.folders
        bookmarks = decoded.bookmarks
    }

    private func save() {
        let persisted = Persisted(folders: folders, bookmarks: bookmarks)
        if let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Netscape HTML import

    struct ImportOutcome {
        var added: Int
        var skipped: Int
    }

    enum ImportError: Error {
        case noBookmarksFound
    }

    /// Parses a Netscape bookmark file (Brave / Chrome / Firefox export).
    /// Folder nesting is restored from <DL>/<H3> structure, ADD_DATE is
    /// honoured, entities are decoded, and javascript: bookmarklets are
    /// kept. Merging skips URLs that already exist.
    func importNetscape(data: Data) throws -> ImportOutcome {
        guard let text = Self.decodeText(data) else { throw ImportError.noBookmarksFound }

        let pattern = #"(?is)(<DL\b[^>]*>|</DL\s*>|<H3\b[^>]*>(.*?)</H3>|<A\b([^>]*)>(.*?)</A>)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw ImportError.noBookmarksFound
        }
        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: fullRange)

        var stack: [UUID?] = [nil] // folder IDs by depth; nil = root
        var pendingFolder: UUID?
        var parsed: [(title: String, url: String, folderID: UUID?, date: Date?)] = []
        var seenInFile = Set<String>()

        func currentFolder() -> UUID? { stack[stack.count - 1] }

        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            guard index < match.numberOfRanges,
                  let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }

        for match in matches {
            guard let token = group(match, 1) else { continue }
            let upper = token.uppercased()
            if upper.hasPrefix("</DL") {
                if stack.count > 1 { stack.removeLast() }
                pendingFolder = nil
            } else if upper.hasPrefix("<DL") {
                stack.append(pendingFolder ?? currentFolder())
                pendingFolder = nil
            } else if upper.hasPrefix("<H3") {
                let name = Self.decodeEntities(group(match, 2) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    pendingFolder = findOrCreateFolder(name: name, parentID: currentFolder())
                }
            } else if upper.hasPrefix("<A") {
                let attrs = group(match, 3) ?? ""
                let titleRaw = group(match, 4) ?? ""
                guard let href = Self.attribute("HREF", in: attrs) else { continue }
                let url = Self.decodeEntities(href)
                guard !url.isEmpty, !url.hasPrefix("place:") else { continue }
                guard !seenInFile.contains(url) else { continue }
                seenInFile.insert(url)
                let date = Self.attribute("ADD_DATE", in: attrs)
                    .flatMap { TimeInterval($0) }
                    .map { Date(timeIntervalSince1970: $0) }
                let folderID = currentFolder() ?? defaultFolderID
                parsed.append((title: Self.decodeEntities(titleRaw), url: url,
                               folderID: folderID, date: date))
            }
        }

        guard !parsed.isEmpty else { throw ImportError.noBookmarksFound }

        var added = 0
        var skipped = 0
        let existing = Set(bookmarks.map { $0.url })
        for entry in parsed {
            if existing.contains(entry.url) {
                skipped += 1
            } else {
                bookmarks.append(Bookmark(id: UUID(),
                                          title: entry.title.isEmpty ? entry.url : entry.title,
                                          url: entry.url,
                                          folderID: entry.folderID,
                                          addedAt: entry.date ?? Date()))
                added += 1
            }
        }
        save()
        return ImportOutcome(added: added, skipped: skipped)
    }

    // MARK: - Netscape HTML export

    func exportNetscape() -> String {
        var lines: [String] = [
            "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
            "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
            "<TITLE>Bookmarks</TITLE>",
            "<H1>Bookmarks</H1>",
            "<DL><p>"
        ]
        appendFolderContents(parentID: nil, indent: "    ", into: &lines)
        lines.append("</DL><p>")
        return lines.joined(separator: "\n")
    }

    private func appendFolderContents(parentID: UUID?, indent: String, into lines: inout [String]) {
        for folder in subfolders(of: parentID) {
            let stamp = Int(Date().timeIntervalSince1970)
            lines.append("\(indent)<DT><H3 ADD_DATE=\"\(stamp)\">\(Self.escape(folder.name))</H3>")
            lines.append("\(indent)<DL><p>")
            appendFolderContents(parentID: folder.id, indent: indent + "    ", into: &lines)
            lines.append("\(indent)</DL><p>")
        }
        for bookmark in bookmarks(in: parentID) {
            let stamp = Int(bookmark.addedAt.timeIntervalSince1970)
            lines.append("\(indent)<DT><A HREF=\"\(Self.escape(bookmark.url))\" ADD_DATE=\"\(stamp)\">\(Self.escape(bookmark.title))</A>")
        }
    }

    // MARK: - Text helpers

    private static func decodeText(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .shiftJIS) { return text }
        return String(data: data, encoding: .windowsCP1252)
    }

    private static func attribute(_ name: String, in attrs: String) -> String? {
        let pattern = "(?i)\(name)\\s*=\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: attrs, range: NSRange(attrs.startIndex..., in: attrs)),
              let range = Range(match.range(at: 1), in: attrs) else { return nil }
        return String(attrs[range])
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        // Numeric references first (decimal and hex).
        if let regex = try? NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let full = Range(match.range, in: result),
                      let codeRange = Range(match.range(at: 1), in: result) else { continue }
                let code = String(result[codeRange])
                let value = code.hasPrefix("x") || code.hasPrefix("X")
                    ? UInt32(String(code.dropFirst()), radix: 16)
                    : UInt32(code)
                if let value, let scalar = Unicode.Scalar(value) {
                    result.replaceSubrange(full, with: String(scalar))
                }
            }
        }
        result = result
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        return result
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

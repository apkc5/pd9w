import Foundation
import CommonCrypto

/// An HLS failure carrying the user-facing reason verbatim (the
/// Playlist item shows it as-is), per the v0.4.14 research: never
/// a silent or generic failure where the cause is known.
struct HLSDownloadFailure: Error {
    let message: String
}

/// The assembled output of an HLS download, still in a temporary
/// location; the caller moves it into the Playlist directory.
struct HLSDownloadOutput {
    /// A single .mp4 file (fMP4 playlists), or a folder holding
    /// segment files + playlist.m3u8 (MPEG-TS playlists).
    var url: URL
    var isFolder: Bool
    var totalBytes: Int64
}

/// Manual HLS saver (v0.4.14, RESEARCH_blob_playlist.md §5.2/5.3).
/// Parses the playlist, downloads the segments natively — every
/// request goes through the caller's request maker, which bakes
/// in the page's cookies, the WebView UA and the Referer — and
/// assembles a playable result:
///
///  - fMP4 (EXT-X-MAP present): the init segment plus the media
///    segments concatenated into ONE .mp4. That byte sequence IS
///    a fragmented MP4, playable as-is, so the Playlist
///    single-file model (thumbnail, ZIP export) holds unchanged.
///  - MPEG-TS: the segments stay as files next to a rewritten
///    local playlist.m3u8 (a hand-rolled .movpkg). AVPlayer plays
///    a local playlist through its HLS path, while a bare .ts
///    file is not something AVURLAsset opens.
///
/// AES-128 segments (METHOD=AES-128) are decrypted with
/// CommonCrypto. Refused up front, with the reason on the item:
/// SAMPLE-AES / skd:// keys (FairPlay DRM), live playlists (no
/// EXT-X-ENDLIST), and master playlists whose audio is a separate
/// rendition (concatenating the video playlist alone would
/// silently produce a mute file). No size cap anywhere — the
/// user's standing call is unlimited; segment bytes are written
/// to disk as they arrive, so memory stays flat.
final class HLSDownloader {
    /// Builds a fully-headered request for one URL (playlist,
    /// key or segment).
    typealias RequestMaker = (URL) async -> URLRequest

    private let makeRequest: RequestMaker
    private let session: URLSession

    init(makeRequest: @escaping RequestMaker) {
        self.makeRequest = makeRequest
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3_600
        self.session = URLSession(configuration: config)
    }

    /// Downloads the stream at `url`. `progress` reports
    /// (segmentsDone, segmentsTotal) on an arbitrary queue.
    func download(from url: URL,
                  progress: @escaping (Int, Int) -> Void) async throws -> HLSDownloadOutput {
        let text = try await fetchText(url)
        if text.contains("#EXT-X-STREAM-INF") {
            if Self.hasSeparateAudioRendition(text) {
                throw HLSDownloadFailure(
                    message: "音声が別ストリームのHLSには未対応です")
            }
            guard let variant = Self.bestVariantURL(in: text, base: url) else {
                throw HLSDownloadFailure(
                    message: "保存に失敗しました（再生用プレイリストが見つかりません）")
            }
            let mediaText = try await fetchText(variant)
            return try await downloadMediaPlaylist(mediaText, base: variant,
                                                   progress: progress)
        }
        return try await downloadMediaPlaylist(text, base: url,
                                               progress: progress)
    }

    // MARK: - Media playlist

    private func downloadMediaPlaylist(_ text: String, base: URL,
                                       progress: @escaping (Int, Int) -> Void) async throws -> HLSDownloadOutput {
        if text.contains("SAMPLE-AES") || text.contains("skd://") {
            throw HLSDownloadFailure(
                message: "DRMで保護されているため保存できません")
        }
        guard text.contains("#EXT-X-ENDLIST") else {
            throw HLSDownloadFailure(message: "ライブ配信は保存できません")
        }
        let parsed = Self.parseMediaPlaylist(text, base: base)
        guard !parsed.segments.isEmpty else {
            throw HLSDownloadFailure(
                message: "保存に失敗しました（セグメントが見つかりません）")
        }

        // Encryption: only the playlist's (first) EXT-X-KEY is
        // honoured; key rotation mid-playlist is out of scope.
        var keyData: Data?
        var keyIV: Data?
        if let key = parsed.key {
            switch key.method {
            case "NONE":
                break
            case "AES-128":
                guard let keyURL = key.uri else {
                    throw HLSDownloadFailure(
                        message: "保存に失敗しました（暗号鍵のURLがありません）")
                }
                let fetched = try await fetchData(keyURL)
                guard fetched.count == 16 else {
                    throw HLSDownloadFailure(
                        message: "保存に失敗しました（暗号鍵を取得できません）")
                }
                keyData = fetched
                keyIV = key.iv
            default:
                throw HLSDownloadFailure(
                    message: "未対応の暗号化方式のため保存できません（\(key.method)）")
            }
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
        let total = parsed.segments.count

        if let mapURL = parsed.mapURL {
            // fMP4: init + segments concatenated into one file.
            let file = tempRoot.appendingPathComponent("hls-\(UUID().uuidString).mp4")
            fileManager.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            var written: Int64 = 0
            do {
                let initData = try await fetchData(mapURL)
                try handle.write(contentsOf: initData)
                written += Int64(initData.count)
                for (index, segment) in parsed.segments.enumerated() {
                    if Task.isCancelled { throw CancellationError() }
                    var data = try await fetchData(segment.url)
                    if let keyData {
                        let iv = keyIV ?? Self.sequenceIV(parsed.mediaSequence + index)
                        guard let plain = Self.decryptAES128(data: data, key: keyData, iv: iv) else {
                            throw HLSDownloadFailure(
                                message: "保存に失敗しました（セグメントの復号に失敗）")
                        }
                        data = plain
                    }
                    try handle.write(contentsOf: data)
                    written += Int64(data.count)
                    progress(index + 1, total)
                }
                try handle.close()
            } catch {
                try? handle.close()
                try? fileManager.removeItem(at: file)
                throw error
            }
            return HLSDownloadOutput(url: file, isFolder: false, totalBytes: written)
        }

        // MPEG-TS: keep the segments, rewrite the playlist locally.
        let folder = tempRoot.appendingPathComponent("hls-\(UUID().uuidString)",
                                                     isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: Int64 = 0
        var localLines: [String] = []
        let targetDuration = max(1, Int(parsed.segments.map { $0.duration }.max()?.rounded(.up) ?? 10))
        localLines.append("#EXTM3U")
        localLines.append("#EXT-X-VERSION:3")
        localLines.append("#EXT-X-TARGETDURATION:\(targetDuration)")
        localLines.append("#EXT-X-MEDIA-SEQUENCE:0")
        do {
            for (index, segment) in parsed.segments.enumerated() {
                if Task.isCancelled { throw CancellationError() }
                var data = try await fetchData(segment.url)
                if let keyData {
                    let iv = keyIV ?? Self.sequenceIV(parsed.mediaSequence + index)
                    guard let plain = Self.decryptAES128(data: data, key: keyData, iv: iv) else {
                        throw HLSDownloadFailure(
                            message: "保存に失敗しました（セグメントの復号に失敗）")
                    }
                    data = plain
                }
                let name = String(format: "seg%05d.ts", index)
                try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                written += Int64(data.count)
                localLines.append(String(format: "#EXTINF:%.3f,", segment.duration))
                localLines.append(name)
                progress(index + 1, total)
            }
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
        localLines.append("#EXT-X-ENDLIST")
        let playlistText = localLines.joined(separator: "\n") + "\n"
        let playlistData = Data(playlistText.utf8)
        try playlistData.write(to: folder.appendingPathComponent("playlist.m3u8"),
                               options: .atomic)
        written += Int64(playlistData.count)
        return HLSDownloadOutput(url: folder, isFolder: true, totalBytes: written)
    }

    // MARK: - Fetching

    private func fetchText(_ url: URL) async throws -> String {
        let data = try await fetchData(url)
        return String(decoding: data, as: UTF8.self)
    }

    private func fetchData(_ url: URL) async throws -> Data {
        let request = await makeRequest(url)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            if http.statusCode == 403 {
                throw HLSDownloadFailure(
                    message: "保存に失敗しました（HTTP 403：アクセスが拒否されました。要ログインの可能性）")
            }
            throw HLSDownloadFailure(
                message: "保存に失敗しました（HTTP \(http.statusCode)）")
        }
        return data
    }

    // MARK: - Parsing

    private struct KeyInfo {
        var method: String
        var uri: URL?
        var iv: Data?
    }

    private struct ParsedPlaylist {
        var segments: [(url: URL, duration: Double)] = []
        var mapURL: URL?
        var key: KeyInfo?
        var mediaSequence: Int = 0
    }

    private static func parseMediaPlaylist(_ text: String, base: URL) -> ParsedPlaylist {
        var parsed = ParsedPlaylist()
        var pendingDuration: Double = 10
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count)
                    .split(separator: ",").first ?? ""
                pendingDuration = Double(value) ?? 10
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                parsed.mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-MAP:") {
                if let uri = attribute("URI", in: line),
                   let resolved = URL(string: uri, relativeTo: base)?.absoluteURL {
                    parsed.mapURL = resolved
                }
            } else if line.hasPrefix("#EXT-X-KEY:"), parsed.key == nil {
                let method = attribute("METHOD", in: line) ?? "NONE"
                let uri = attribute("URI", in: line)
                    .flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
                let iv = attribute("IV", in: line).flatMap { hexData($0) }
                parsed.key = KeyInfo(method: method, uri: uri, iv: iv)
            } else if !line.hasPrefix("#"), !line.isEmpty {
                if let resolved = URL(string: line, relativeTo: base)?.absoluteURL {
                    parsed.segments.append((resolved, pendingDuration))
                }
            }
        }
        return parsed
    }

    /// The highest-bandwidth variant of a master playlist (the
    /// user's call is best quality, no caps).
    private static func bestVariantURL(in text: String, base: URL) -> URL? {
        var best: (bandwidth: Int, url: URL)?
        var pendingBandwidth = 0
        var expectingURI = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingBandwidth = attribute("BANDWIDTH", in: line).flatMap { Int($0) } ?? 0
                expectingURI = true
            } else if expectingURI, !line.hasPrefix("#"), !line.isEmpty {
                if let resolved = URL(string: line, relativeTo: base)?.absoluteURL,
                   best == nil || pendingBandwidth > (best?.bandwidth ?? 0) {
                    best = (pendingBandwidth, resolved)
                }
                expectingURI = false
            }
        }
        return best?.url
    }

    /// A master that lists its audio as a separate rendition
    /// playlist (EXT-X-MEDIA TYPE=AUDIO with its own URI): saving
    /// the video playlist alone would produce a mute file.
    private static func hasSeparateAudioRendition(_ text: String) -> Bool {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MEDIA:"),
               line.contains("TYPE=AUDIO"), line.contains("URI=") {
                return true
            }
        }
        return false
    }

    /// Reads one `NAME=value` attribute out of an HLS tag line;
    /// the value may be double-quoted.
    private static func attribute(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: name + "=") else { return nil }
        let rest = line[range.upperBound...]
        if rest.hasPrefix("\"") {
            let inner = rest.dropFirst()
            if let end = inner.firstIndex(of: "\"") {
                return String(inner[..<end])
            }
            return String(inner)
        }
        return String(rest.prefix { $0 != "," })
    }

    private static func hexData(_ string: String) -> Data? {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("0x") || text.hasPrefix("0X") { text = String(text.dropFirst(2)) }
        guard text.count % 2 == 0, !text.isEmpty else { return nil }
        var data = Data()
        data.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// The default IV for AES-128 segments: the segment's media
    /// sequence number as a 128-bit big-endian integer.
    private static func sequenceIV(_ sequence: Int) -> Data {
        var data = Data(count: 16)
        var value = sequence
        var position = 15
        while value > 0, position >= 0 {
            data[position] = UInt8(value & 0xff)
            value >>= 8
            position -= 1
        }
        return data
    }

    // MARK: - AES-128 (CommonCrypto)

    private static func decryptAES128(data: Data, key: Data, iv: Data) -> Data? {
        let keyBytes = [UInt8](key)
        let ivBytes = [UInt8](iv)
        let dataBytes = [UInt8](data)
        var out = [UInt8](repeating: 0, count: dataBytes.count + kCCBlockSizeAES128)
        var outLength = 0
        let status = CCCrypt(CCOperation(kCCDecrypt),
                             CCAlgorithm(kCCAlgorithmAES),
                             CCOptions(kCCOptionPKCS7Padding),
                             keyBytes, keyBytes.count, ivBytes,
                             dataBytes, dataBytes.count,
                             &out, out.count, &outLength)
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(outLength...)
        return Data(out)
    }
}

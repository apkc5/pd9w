import Foundation

/// Minimal streaming ZIP writer (v0.4.9, Playlist export): stored
/// (uncompressed) entries only — playlist files are already-compressed
/// media, so recompression would burn CPU for nothing. Files are
/// streamed through a FileHandle in chunks; nothing is ever fully
/// loaded into memory, so multi-hundred-MB exports stay safe.
///
/// Format notes: each entry is written as local header + data, with
/// the CRC-32 and sizes computed in a pre-pass over the source file
/// (a second sequential read — cheap next to the copy itself), then
/// a central directory at the end. No ZIP64: totals here stay far
/// below 4GB in practice, and the writer throws if an entry would
/// exceed the classic limits instead of emitting a corrupt archive.
final class ZipWriter {
    enum ZipError: Error {
        case tooLarge
        case ioFailure(String)
    }

    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var entries: [(name: [UInt8], crc: UInt32, size: UInt32, headerOffset: UInt32)] = []

    init(outputURL: URL) throws {
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        do {
            handle = try FileHandle(forWritingTo: outputURL)
        } catch {
            throw ZipError.ioFailure(error.localizedDescription)
        }
    }

    /// Appends one file under the given archive name (UTF-8).
    func addFile(at fileURL: URL, archiveName: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard size <= UInt64(UInt32.max), offset <= UInt64(UInt32.max) else {
            throw ZipError.tooLarge
        }
        let crc = try Self.crc32(of: fileURL)
        let nameBytes = [UInt8](archiveName.utf8)
        let headerOffset = UInt32(offset)

        var header = Data()
        header.appendUInt32(0x04034b50)          // local file header
        header.appendUInt16(20)                  // version needed
        header.appendUInt16(0x0800)              // UTF-8 filename flag
        header.appendUInt16(0)                   // method: stored
        header.appendUInt16(0)                   // mod time
        header.appendUInt16(0x21)                // mod date (1980-01-01)
        header.appendUInt32(crc)
        header.appendUInt32(UInt32(size))        // compressed size
        header.appendUInt32(UInt32(size))        // uncompressed size
        header.appendUInt16(UInt16(nameBytes.count))
        header.appendUInt16(0)                   // extra length
        header.append(contentsOf: nameBytes)
        try write(header)

        // Stream the payload through in 256KB chunks.
        let reader = try FileHandle(forReadingFrom: fileURL)
        defer { try? reader.close() }
        while true {
            let chunk = try reader.read(upToCount: 262_144) ?? Data()
            if chunk.isEmpty { break }
            try write(chunk)
        }
        entries.append((nameBytes, crc, UInt32(size), headerOffset))
    }

    /// Writes the central directory and end record. Call once.
    func finish() throws {
        let directoryOffset = offset
        guard directoryOffset <= UInt64(UInt32.max) else { throw ZipError.tooLarge }
        for entry in entries {
            var record = Data()
            record.appendUInt32(0x02014b50)      // central directory
            record.appendUInt16(20)              // version made by
            record.appendUInt16(20)              // version needed
            record.appendUInt16(0x0800)          // UTF-8 filename flag
            record.appendUInt16(0)               // stored
            record.appendUInt16(0)               // mod time
            record.appendUInt16(0x21)            // mod date
            record.appendUInt32(entry.crc)
            record.appendUInt32(entry.size)
            record.appendUInt32(entry.size)
            record.appendUInt16(UInt16(entry.name.count))
            record.appendUInt16(0)               // extra
            record.appendUInt16(0)               // comment
            record.appendUInt16(0)               // disk number
            record.appendUInt16(0)               // internal attrs
            record.appendUInt32(0)               // external attrs
            record.appendUInt32(entry.headerOffset)
            record.append(contentsOf: entry.name)
            try write(record)
        }
        let directorySize = offset - directoryOffset
        var end = Data()
        end.appendUInt32(0x06054b50)             // end of central dir
        end.appendUInt16(0)
        end.appendUInt16(0)
        end.appendUInt16(UInt16(entries.count))
        end.appendUInt16(UInt16(entries.count))
        end.appendUInt32(UInt32(directorySize))
        end.appendUInt32(UInt32(directoryOffset))
        end.appendUInt16(0)                      // comment length
        try write(end)
        try handle.close()
    }

    private func write(_ data: Data) throws {
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw ZipError.ioFailure(error.localizedDescription)
        }
        offset += UInt64(data.count)
    }

    // MARK: - CRC-32 (IEEE, table-driven)

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func crc32(of fileURL: URL) throws -> UInt32 {
        let reader = try FileHandle(forReadingFrom: fileURL)
        defer { try? reader.close() }
        var crc: UInt32 = 0xFFFFFFFF
        while true {
            let chunk = try reader.read(upToCount: 262_144) ?? Data()
            if chunk.isEmpty { break }
            for byte in chunk {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: 2))
    }

    mutating func appendUInt32(_ value: UInt32) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: 4))
    }
}

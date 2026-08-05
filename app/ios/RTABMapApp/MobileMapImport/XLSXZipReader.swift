import Foundation
import zlib

/// Minimal, hardened ZIP reader used for XLSX parsing on device.
///
/// The app already links zlib; this reader parses the end-of-central
/// directory and the central directory directly and inflates `deflate`
/// entries with raw `inflate` (windowBits = -15). It enforces the frozen
/// XLSX safety policy: no path traversal, no absolute entries, bounded
/// entry count, bounded per-entry and total uncompressed size, and a
/// bounded compression ratio (ZIP-bomb defence). Formulas and external
/// relationships are never executed — this reader only extracts bytes.
enum XLSXZipReader {
    struct Entry {
        var name: String
        var data: Data
    }

    static let maximumEntries = MapSourceImportLimits.maximumZIPEntries
    static let maximumEntryBytes = MapSourceImportLimits.maximumZIPEntryBytes
    static let maximumTotalBytes = MapSourceImportLimits.maximumZIPTotalBytes
    static let maximumRatio: Int64 = MapSourceImportLimits.maximumZIPRatio

    static func readEntries(data: Data) throws -> [Entry] {
        guard data.count >= 22 else {
            throw MapSourceImportError.zipCorrupt(reason: "文件过小。")
        }
        let endRecord = try locateEndOfCentralDirectory(data)
        let end = try parseEndOfCentralDirectory(data, at: endRecord)

        var entries: [Entry] = []
        var totalBytes: Int64 = 0
        var cursor = end.centralDirectoryOffset
        for _ in 0..<end.entryCount {
            guard cursor + 46 <= data.count else {
                throw MapSourceImportError.zipCorrupt(reason: "中央目录越界。")
            }
            let signature = readUInt32(data, at: cursor)
            guard signature == 0x02014B50 else {
                throw MapSourceImportError.zipCorrupt(reason: "中央目录签名缺失。")
            }
            let compressedSize = readUInt32(data, at: cursor + 20)
            let uncompressedSize = readUInt32(data, at: cursor + 24)
            let nameLength = Int(readUInt16(data, at: cursor + 28))
            let extraLength = Int(readUInt16(data, at: cursor + 30))
            let commentLength = Int(readUInt16(data, at: cursor + 32))
            let localHeaderOffset = readUInt32(data, at: cursor + 42)
            let method = readUInt16(data, at: cursor + 10)

            guard nameLength > 0, cursor + 46 + nameLength <= data.count else {
                throw MapSourceImportError.zipCorrupt(reason: "条目名越界。")
            }
            let nameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw MapSourceImportError.zipCorrupt(reason: "条目名非法 UTF-8。")
            }
            try validateEntryName(name)

            let payload = try extractEntryPayload(
                data: data,
                name: name,
                method: Int(method),
                compressedSize: Int64(compressedSize),
                uncompressedSize: Int64(uncompressedSize),
                localHeaderOffset: Int(localHeaderOffset),
                totalBytes: &totalBytes
            )
            entries.append(Entry(name: name, data: payload))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func validateEntryName(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.hasPrefix("\\"),
              !name.contains("..") else {
            throw MapSourceImportError.zipTraversalDetected(entry: name)
        }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        for component in components {
            guard component != ".." else {
                throw MapSourceImportError.zipTraversalDetected(entry: name)
            }
        }
    }

    private static func extractEntryPayload(
        data: Data,
        name: String,
        method: Int,
        compressedSize: Int64,
        uncompressedSize: Int64,
        localHeaderOffset: Int,
        totalBytes: inout Int64
    ) throws -> Data {
        guard method == 0 || method == 8 else {
            throw MapSourceImportError.zipCorrupt(reason: "不支持的压缩方法（\(method)）。")
        }
        guard uncompressedSize <= maximumEntryBytes else {
            throw MapSourceImportError.zipEntryTooLarge(entry: name)
        }
        guard totalBytes + uncompressedSize <= maximumTotalBytes else {
            throw MapSourceImportError.zipTotalTooLarge(limitBytes: maximumTotalBytes)
        }
        if method == 8 {
            guard compressedSize > 0,
                  uncompressedSize <= compressedSize * maximumRatio else {
                throw MapSourceImportError.zipRatioTooLarge(entry: name)
            }
        }
        guard localHeaderOffset + 30 <= data.count else {
            throw MapSourceImportError.zipCorrupt(reason: "本地文件头越界。")
        }
        let localSignature = readUInt32(data, at: localHeaderOffset)
        guard localSignature == 0x04034B50 else {
            throw MapSourceImportError.zipCorrupt(reason: "本地文件头签名缺失。")
        }
        let localNameLength = Int(readUInt16(data, at: localHeaderOffset + 26))
        let localExtraLength = Int(readUInt16(data, at: localHeaderOffset + 28))
        let payloadStart = localHeaderOffset + 30 + localNameLength + localExtraLength
        let payloadEnd = payloadStart + Int(compressedSize)
        guard payloadStart >= 0, payloadEnd <= data.count else {
            throw MapSourceImportError.zipCorrupt(reason: "条目数据越界。")
        }
        let compressed = data.subdata(in: payloadStart..<payloadEnd)
        let payload: Data
        if method == 0 {
            payload = compressed
        } else {
            payload = try inflateRaw(compressed, expectedSize: Int(uncompressedSize), name: name)
        }
        guard Int64(payload.count) == uncompressedSize else {
            throw MapSourceImportError.zipCorrupt(reason: "条目尺寸不一致。")
        }
        totalBytes += Int64(payload.count)
        return payload
    }

    private static func inflateRaw(_ compressed: Data, expectedSize: Int, name: String) throws -> Data {
        var stream = z_stream()
        stream.next_in = UnsafeMutablePointer(mutating: (compressed as NSData).bytes.bindMemory(to: Bytef.self, capacity: compressed.count))
        stream.avail_in = uInt(compressed.count)
        var result = Data(count: expectedSize)
        stream.next_out = result.withUnsafeMutableBytes { buffer in
            buffer.bindMemory(to: Bytef.self).baseAddress
        }
        stream.avail_out = uInt(expectedSize)
        let initCode = inflateInit2_(
            &stream,
            -15,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initCode == Z_OK else {
            throw MapSourceImportError.zipCorrupt(reason: "inflate 初始化失败。")
        }
        defer { inflateEnd(&stream) }
        let code = inflate(&stream, Z_FINISH)
        guard code == Z_STREAM_END, stream.total_out == uLong(expectedSize) else {
            throw MapSourceImportError.zipCorrupt(reason: "条目 \(name) 解压失败。")
        }
        return result
    }

    private static func locateEndOfCentralDirectory(_ data: Data) throws -> Int {
        // EOCD is at most 65_557 bytes from the end (comment limit).
        let searchStart = max(0, data.count - 65_557)
        let bytes = Array(data[searchStart..<data.count])
        guard let position = bytes.lastIndex(where: { $0 == 0x50 }) else {
            throw MapSourceImportError.zipCorrupt(reason: "找不到中央目录结束标记。")
        }
        let relative = position
        let absolute = searchStart + relative
        guard absolute + 22 <= data.count,
              readUInt32(data, at: absolute) == 0x06054B50 else {
            throw MapSourceImportError.zipCorrupt(reason: "中央目录结束标记无效。")
        }
        return absolute
    }

    private static func parseEndOfCentralDirectory(
        _ data: Data, at offset: Int
    ) throws -> (entryCount: Int, centralDirectoryOffset: Int) {
        let entryCount = Int(readUInt16(data, at: offset + 10))
        let centralDirectoryOffset = Int(readUInt32(data, at: offset + 16))
        guard centralDirectoryOffset >= 0, centralDirectoryOffset < data.count else {
            throw MapSourceImportError.zipCorrupt(reason: "中央目录偏移越界。")
        }
        return (entryCount, centralDirectoryOffset)
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        var value: UInt16 = 0
        for index in 0..<2 {
            value |= UInt16(data[offset + index]) << (8 * index)
        }
        return value
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(data[offset + index]) << (8 * index)
        }
        return value
    }
}

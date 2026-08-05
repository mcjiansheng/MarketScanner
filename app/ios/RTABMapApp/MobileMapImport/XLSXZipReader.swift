import Foundation
import zlib

/// Hardened ZIP reader used for XLSX parsing on device (V1R1 §6.2).
///
/// Contract implemented here:
/// - EOCD: search for the *last complete* signature whose comment length
///   exactly reaches the file end (a `P` inside a long comment or a false
///   EOCD byte can never hijack the parse).
/// - Reject multi-disk archives and ZIP64 (either explicit ZIP64 EOCD or
///   any 0xFFFFFFFF size/offset field).
/// - Reject encrypted entries (general-purpose bit 0 / 0x40).
/// - Entry count is validated from the EOCD *before* any extraction.
/// - Central directory bounds are exact (offset + size == EOCD offset).
/// - Duplicate entry names are rejected (also under Unicode
///   normalization, so a NFD name cannot shadow an NFC name).
/// - Local header name / method / sizes must match the central record.
/// - CRC32 of every extracted entry is verified.
/// - Compression ratio and total uncompressed size are bounded (ZIP-bomb
///   defence); canonical path components only (no traversal, no
///   backslash paths, no absolute entries).
enum XLSXZipReader {
    struct Entry {
        var name: String
        var data: Data
    }

    static let maximumEntries = MapSourceImportLimits.maximumZIPEntries
    static let maximumEntryBytes = MapSourceImportLimits.maximumZIPEntryBytes
    static let maximumTotalBytes = MapSourceImportLimits.maximumZIPTotalBytes
    static let maximumRatio: Int64 = MapSourceImportLimits.maximumZIPRatio

    private static let localFileHeaderSignature: UInt32 = 0x04034B50
    private static let centralDirectorySignature: UInt32 = 0x02014B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x06054B50
    private static let zip64EndOfCentralDirectorySignature: UInt32 = 0x06064B50
    private static let zip64EndOfCentralDirectoryLocatorSignature: UInt32 = 0x07064B50
    private static let maximumEOCDSearchBytes = 65_557

    static func readEntries(data: Data) throws -> [Entry] {
        guard data.count >= 22 else {
            throw MapSourceImportError.zipCorrupt(reason: "文件过小。")
        }
        // Reject explicit ZIP64 structures up front.
        if scanForSignature(data, signature: zip64EndOfCentralDirectorySignature)
            || scanForSignature(data, signature: zip64EndOfCentralDirectoryLocatorSignature) {
            throw MapSourceImportError.zipCorrupt(reason: "不支持 ZIP64。")
        }
        let endOffset = try locateEndOfCentralDirectory(data)
        let end = try parseEndOfCentralDirectory(data, at: endOffset)

        // Entry count is validated before any extraction.
        guard end.entryCount <= maximumEntries else {
            throw MapSourceImportError.zipEntryTooMany(limit: maximumEntries)
        }
        // Exact central directory bounds: offset + size must end exactly
        // at the EOCD record.
        guard end.centralDirectoryOffset + end.centralDirectorySize == endOffset,
              end.centralDirectorySize <= data.count - end.centralDirectoryOffset else {
            throw MapSourceImportError.zipCorrupt(reason: "中央目录边界不一致。")
        }

        var entries: [Entry] = []
        var seenNames: Set<String> = []
        var totalBytes: Int64 = 0
        var cursor = end.centralDirectoryOffset
        for _ in 0..<end.entryCount {
            guard cursor + 46 <= data.count else {
                throw MapSourceImportError.zipCorrupt(reason: "中央目录越界。")
            }
            let signature = readUInt32(data, at: cursor)
            guard signature == centralDirectorySignature else {
                throw MapSourceImportError.zipCorrupt(reason: "中央目录签名缺失。")
            }
            let flags = readUInt16(data, at: cursor + 8)
            let method = readUInt16(data, at: cursor + 10)
            let crc32Value = readUInt32(data, at: cursor + 16)
            let compressedSize = readUInt32(data, at: cursor + 20)
            let uncompressedSize = readUInt32(data, at: cursor + 24)
            let nameLength = Int(readUInt16(data, at: cursor + 28))
            let extraLength = Int(readUInt16(data, at: cursor + 30))
            let commentLength = Int(readUInt16(data, at: cursor + 32))
            let diskStart = readUInt16(data, at: cursor + 34)
            let localHeaderOffset = readUInt32(data, at: cursor + 42)

            guard nameLength > 0, cursor + 46 + nameLength <= data.count else {
                throw MapSourceImportError.zipCorrupt(reason: "条目名越界。")
            }
            let nameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw MapSourceImportError.zipCorrupt(reason: "条目名非法 UTF-8。")
            }
            try validateEntryName(name)
            // Duplicate names rejected, including Unicode-normalization
            // collisions (NFD vs NFC cannot shadow each other).
            let canonicalName = name.precomposedStringWithCanonicalMapping
            guard seenNames.insert(canonicalName).inserted else {
                throw MapSourceImportError.zipCorrupt(reason: "重复条目名：\(name)")
            }

            // Encryption and general-purpose flag policy.
            try validateGeneralPurposeFlags(flags, name: name)
            // Multi-disk archives are rejected in EOCD; entries must not
            // point at another disk either.
            guard diskStart == 0 else {
                throw MapSourceImportError.zipCorrupt(reason: "不支持跨磁盘条目。")
            }
            // ZIP64: a 0xFFFFFFFF sentinel in any 32-bit field is
            // rejected (we do not parse ZIP64 extras).
            if compressedSize == 0xFFFFFFFF || uncompressedSize == 0xFFFFFFFF
                || localHeaderOffset == 0xFFFFFFFF || nameLength == 0xFFFF {
                throw MapSourceImportError.zipCorrupt(reason: "不支持 ZIP64。")
            }

            let payload = try extractEntryPayload(
                data: data,
                name: name,
                method: Int(method),
                flags: flags,
                crc32Value: crc32Value,
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

    // MARK: - EOCD

    private static func scanForSignature(_ data: Data, signature: UInt32) -> Bool {
        guard data.count >= 4 else { return false }
        let expected = [
            UInt8(signature & 0xFF),
            UInt8((signature >> 8) & 0xFF),
            UInt8((signature >> 16) & 0xFF),
            UInt8((signature >> 24) & 0xFF),
        ]
        for index in 0...(data.count - 4) {
            if data[index] == expected[0], data[index + 1] == expected[1],
               data[index + 2] == expected[2], data[index + 3] == expected[3] {
                return true
            }
        }
        return false
    }

    /// Finds the last complete EOCD record: the signature whose comment
    /// length exactly reaches the file end. False signatures inside the
    /// comment are skipped by validating the comment length.
    private static func locateEndOfCentralDirectory(_ data: Data) throws -> Int {
        let searchStart = max(0, data.count - maximumEOCDSearchBytes)
        var offset = data.count - 22
        while offset >= searchStart {
            if readUInt32(data, at: offset) == endOfCentralDirectorySignature {
                let commentLength = Int(readUInt16(data, at: offset + 20))
                if offset + 22 + commentLength == data.count {
                    return offset
                }
            }
            offset -= 1
        }
        throw MapSourceImportError.zipCorrupt(reason: "找不到完整中央目录结束标记。")
    }

    private struct EndOfCentralDirectory {
        var entryCount: Int
        var centralDirectoryOffset: Int
        var centralDirectorySize: Int
    }

    private static func parseEndOfCentralDirectory(
        _ data: Data, at offset: Int
    ) throws -> EndOfCentralDirectory {
        let diskNumber = readUInt16(data, at: offset + 4)
        let centralDiskNumber = readUInt16(data, at: offset + 6)
        let entryCountOnDisk = Int(readUInt16(data, at: offset + 8))
        let totalEntryCount = Int(readUInt16(data, at: offset + 10))
        let centralDirectorySize = Int(readUInt32(data, at: offset + 12))
        let centralDirectoryOffset = Int(readUInt32(data, at: offset + 16))

        guard diskNumber == 0, centralDiskNumber == 0 else {
            throw MapSourceImportError.zipCorrupt(reason: "不支持多磁盘归档。")
        }
        guard entryCountOnDisk == totalEntryCount else {
            throw MapSourceImportError.zipCorrupt(reason: "条目数不一致（多磁盘）。")
        }
        guard centralDirectoryOffset >= 0, centralDirectoryOffset < data.count else {
            throw MapSourceImportError.zipCorrupt(reason: "中央目录偏移越界。")
        }
        if totalEntryCount == 0xFFFF {
            // ZIP64 sentinel; we already rejected explicit ZIP64, so a
            // sentinel count is invalid here.
            throw MapSourceImportError.zipCorrupt(reason: "不支持 ZIP64。")
        }
        return EndOfCentralDirectory(
            entryCount: totalEntryCount,
            centralDirectoryOffset: centralDirectoryOffset,
            centralDirectorySize: centralDirectorySize)
    }

    // MARK: - Entry validation

    private static func validateGeneralPurposeFlags(_ flags: UInt16, name: String) throws {
        // Bit 0: encrypted. Bit 6: strong encryption. Both are rejected.
        if flags & 0x0001 != 0 || flags & 0x0040 != 0 {
            throw MapSourceImportError.zipCorrupt(reason: "加密条目不支持：\(name)")
        }
        // Bit 3 (data descriptor) is permitted; sizes are re-read from
        // the local header when present (see extractEntryPayload).
    }

    /// Canonical path components only: no `..`, no `.`, no backslash, no
    /// leading separator, no drive letters, no empty components.
    private static func validateEntryName(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.hasPrefix("\\"),
              !name.contains("\\"), !name.contains(".."),
              !(name.count >= 2 && name[name.index(after: name.startIndex)] == ":")
        else {
            throw MapSourceImportError.zipTraversalDetected(entry: name)
        }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        for component in components {
            guard component != "..", component != "." else {
                throw MapSourceImportError.zipTraversalDetected(entry: name)
            }
        }
    }

    private static func extractEntryPayload(
        data: Data,
        name: String,
        method: Int,
        flags: UInt16,
        crc32Value: UInt32,
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
        guard localSignature == localFileHeaderSignature else {
            throw MapSourceImportError.zipCorrupt(reason: "本地文件头签名缺失。")
        }
        let localFlags = readUInt16(data, at: localHeaderOffset + 6)
        let localMethod = readUInt16(data, at: localHeaderOffset + 8)
        let localCompressedSize = readUInt32(data, at: localHeaderOffset + 18)
        let localUncompressedSize = readUInt32(data, at: localHeaderOffset + 22)
        let localNameLength = Int(readUInt16(data, at: localHeaderOffset + 26))
        let localExtraLength = Int(readUInt16(data, at: localHeaderOffset + 28))

        // Local/central consistency.
        guard Int(localMethod) == method else {
            throw MapSourceImportError.zipCorrupt(reason: "本地/中央压缩方法不一致：\(name)")
        }
        guard localFlags & 0x0001 == flags & 0x0001 else {
            throw MapSourceImportError.zipCorrupt(reason: "本地/中央加密标志不一致：\(name)")
        }
        guard localHeaderOffset + 30 + localNameLength <= data.count else {
            throw MapSourceImportError.zipCorrupt(reason: "本地文件名越界：\(name)")
        }
        let localNameData = data.subdata(
            in: (localHeaderOffset + 30)..<(localHeaderOffset + 30 + localNameLength))
        guard let localName = String(data: localNameData, encoding: .utf8),
              localName == name else {
            throw MapSourceImportError.zipCorrupt(reason: "本地/中央文件名不一致：\(name)")
        }

        let usesDataDescriptor = (flags & 0x0008) != 0
        let localCompressed = Int64(localCompressedSize)
        let localUncompressed = Int64(localUncompressedSize)
        if usesDataDescriptor {
            // Sizes may be zeroed in the local header; the central
            // directory values are authoritative. Anything non-zero must
            // still match the central record.
            if (localCompressed != 0 && localCompressed != compressedSize)
                || (localUncompressed != 0 && localUncompressed != uncompressedSize) {
                throw MapSourceImportError.zipCorrupt(reason: "本地/中央尺寸不一致：\(name)")
            }
        } else {
            guard localCompressed == compressedSize,
                  localUncompressed == uncompressedSize else {
                throw MapSourceImportError.zipCorrupt(reason: "本地/中央尺寸不一致：\(name)")
            }
        }

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
        // CRC32 verification on the extracted bytes (also for method 0).
        let actualCRC = payload.withUnsafeBytes { buffer -> uLong in
            return crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(payload.count))
        }
        guard UInt32(actualCRC) == crc32Value else {
            throw MapSourceImportError.zipCorrupt(reason: "条目 CRC 校验失败：\(name)")
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

    // MARK: - Byte readers

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

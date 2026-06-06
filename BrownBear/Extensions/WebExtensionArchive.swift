//
//  WebExtensionArchive.swift
//  BrownBear
//
//  Unpacks a browser-extension package — a `.crx` (Chrome) or a plain `.zip` — into an in-memory
//  map of path → file data, with no third-party dependency. A `.crx` is a small header followed by
//  a standard ZIP, so we strip the CRX header (CRX2 or CRX3) and read the ZIP ourselves using the
//  system `Compression` framework for DEFLATE.
//

import Compression
import Foundation

enum WebExtensionArchiveError: LocalizedError {
    case notAnArchive
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .notAnArchive: return "The file isn’t a .crx or .zip extension package."
        case .corrupt(let why): return "The extension package is corrupt: \(why)"
        }
    }
}

enum WebExtensionArchive {

    /// Unpack a `.crx`/`.zip` into `path → contents`. Directory entries are omitted.
    static func unpack(_ data: Data) throws -> [String: Data] {
        let zipData = try stripCRXHeaderIfNeeded(data)
        return try readZip(zipData)
    }

    // MARK: - CRX header

    /// If `data` is a CRX (magic "Cr24"), return the embedded ZIP slice; otherwise return `data`.
    private static func stripCRXHeaderIfNeeded(_ data: Data) throws -> Data {
        guard data.count >= 16 else {
            // Too short to be a CRX; assume it is (or isn't) a bare ZIP and let readZip decide.
            return data
        }
        // "Cr24"
        guard data[0] == 0x43, data[1] == 0x72, data[2] == 0x32, data[3] == 0x34 else {
            return data // not a CRX — treat as a bare ZIP
        }
        let version = u32(data, 4)
        switch version {
        case 2:
            let publicKeyLength = Int(u32(data, 8))
            let signatureLength = Int(u32(data, 12))
            let zipStart = 16 + publicKeyLength + signatureLength
            guard zipStart <= data.count else { throw WebExtensionArchiveError.corrupt("CRX2 header overruns file") }
            return data.subdata(in: zipStart..<data.count)
        case 3:
            let headerSize = Int(u32(data, 8))
            let zipStart = 12 + headerSize
            guard zipStart <= data.count else { throw WebExtensionArchiveError.corrupt("CRX3 header overruns file") }
            return data.subdata(in: zipStart..<data.count)
        default:
            throw WebExtensionArchiveError.corrupt("unsupported CRX version \(version)")
        }
    }

    // MARK: - ZIP reader

    private static let eocdSignature: UInt32 = 0x0605_4b50
    private static let centralDirSignature: UInt32 = 0x0201_4b50
    private static let localHeaderSignature: UInt32 = 0x0403_4b50

    private static func readZip(_ data: Data) throws -> [String: Data] {
        guard let eocd = findEOCD(data) else { throw WebExtensionArchiveError.notAnArchive }
        let entryCount = Int(u16(data, eocd + 10))
        var cursor = Int(u32(data, eocd + 16)) // central directory offset

        var files: [String: Data] = [:]
        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count, u32(data, cursor) == centralDirSignature else {
                throw WebExtensionArchiveError.corrupt("bad central directory entry")
            }
            let method = u16(data, cursor + 10)
            let compressedSize = Int(u32(data, cursor + 20))
            let uncompressedSize = Int(u32(data, cursor + 24))
            let nameLength = Int(u16(data, cursor + 28))
            let extraLength = Int(u16(data, cursor + 30))
            let commentLength = Int(u16(data, cursor + 32))
            let localOffset = Int(u32(data, cursor + 42))
            guard cursor + 46 + nameLength <= data.count else {
                throw WebExtensionArchiveError.corrupt("filename overruns central directory")
            }
            let name = String(decoding: data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength)), as: UTF8.self)
            cursor += 46 + nameLength + extraLength + commentLength

            // Directory entries end in "/".
            if name.hasSuffix("/") { continue }

            if let contents = try extractEntry(data, localOffset: localOffset, method: method,
                                               compressedSize: compressedSize, uncompressedSize: uncompressedSize) {
                files[name] = contents
            }
        }
        return files
    }

    private static func extractEntry(_ data: Data, localOffset: Int, method: UInt16,
                                     compressedSize: Int, uncompressedSize: Int) throws -> Data? {
        guard localOffset + 30 <= data.count, u32(data, localOffset) == localHeaderSignature else {
            throw WebExtensionArchiveError.corrupt("bad local file header")
        }
        let nameLength = Int(u16(data, localOffset + 26))
        let extraLength = Int(u16(data, localOffset + 28))
        let dataStart = localOffset + 30 + nameLength + extraLength
        guard dataStart + compressedSize <= data.count else {
            throw WebExtensionArchiveError.corrupt("entry data overruns file")
        }
        let payload = data.subdata(in: dataStart..<(dataStart + compressedSize))

        switch method {
        case 0: // stored
            return payload
        case 8: // deflate
            return inflate(payload, uncompressedSize: uncompressedSize)
        default:
            return nil // unsupported compression — skip rather than fail the whole package
        }
    }

    /// Cap a single entry's uncompressed size: `uncompressedSize` is read verbatim from the
    /// untrusted central directory (up to ~4 GB), so without a ceiling a tiny DEFLATE stream could
    /// drive a multi-GB `Data(count:)` allocation — a zip-bomb DoS / OOM crash on install.
    private static let maxUncompressedEntryBytes = 64 * 1024 * 1024

    /// Inflate a raw DEFLATE stream (ZIP method 8) into `uncompressedSize` bytes.
    private static func inflate(_ input: Data, uncompressedSize: Int) -> Data? {
        if uncompressedSize == 0 { return Data() }
        guard uncompressedSize > 0, uncompressedSize <= maxUncompressedEntryBytes else { return nil }
        var output = Data(count: uncompressedSize)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let dst = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return input.withUnsafeBytes { source -> Int in
                guard let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                // Apple's COMPRESSION_ZLIB decodes RAW DEFLATE (no zlib wrapper), matching ZIP.
                return compression_decode_buffer(dst, uncompressedSize, src, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == uncompressedSize else { return nil }
        return output
    }

    /// Locate the End Of Central Directory record by scanning backwards from the file's end.
    private static func findEOCD(_ data: Data) -> Int? {
        let minSize = 22
        guard data.count >= minSize else { return nil }
        // The EOCD is within the last 22 + 65535 bytes (max comment length).
        let searchStart = max(0, data.count - (minSize + 0xFFFF))
        var index = data.count - minSize
        while index >= searchStart {
            if u32(data, index) == eocdSignature { return index }
            index -= 1
        }
        return nil
    }

    // MARK: - Little-endian readers

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}

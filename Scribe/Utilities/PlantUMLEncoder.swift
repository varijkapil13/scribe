// Scribe/Utilities/PlantUMLEncoder.swift
import Foundation
import zlib

/// Encodes PlantUML source for use with the plantuml.com REST API.
/// Algorithm: UTF-8 → raw DEFLATE → PlantUML custom base64.
/// Usage: append result to "https://www.plantuml.com/plantuml/svg/"
enum PlantUMLEncoder {

    private static let alphabet: [Character] =
        Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_")

    static func encode(_ source: String) -> String? {
        guard let utf8 = source.data(using: .utf8),
              let compressed = rawDeflate(utf8) else { return nil }
        return plantBase64(compressed)
    }

    // MARK: - Private

    private static func rawDeflate(_ data: Data) -> Data? {
        var stream = z_stream()
        // windowBits = -15 → raw DEFLATE (no zlib header/trailer)
        let initResult = deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
            -15, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else { return nil }
        defer { deflateEnd(&stream) }

        let outCapacity = max(data.count * 2, 64)
        var output = Data(count: outCapacity)

        // Use separate byte arrays to avoid overlapping access violations in Swift 6.
        let inputBytes = Array(data)
        var outputBytes = [UInt8](repeating: 0, count: outCapacity)

        let totalOut: Int? = inputBytes.withUnsafeBytes { inBuf in
            guard let inPtr = inBuf.baseAddress?.assumingMemoryBound(to: Bytef.self) else { return nil }
            return outputBytes.withUnsafeMutableBytes { outBuf in
                guard let outPtr = outBuf.baseAddress?.assumingMemoryBound(to: Bytef.self) else { return nil }
                stream.next_in  = UnsafeMutablePointer(mutating: inPtr)
                stream.avail_in = uInt(inputBytes.count)
                stream.next_out = outPtr
                stream.avail_out = uInt(outCapacity)
                guard deflate(&stream, Z_FINISH) == Z_STREAM_END else { return nil }
                return Int(stream.total_out)
            }
        }

        guard let count = totalOut else { return nil }
        output = Data(outputBytes.prefix(count))
        return output
    }

    private static func plantBase64(_ data: Data) -> String {
        var result = ""
        result.reserveCapacity((data.count / 3 + 1) * 4)
        var i = data.startIndex
        while i < data.endIndex {
            let next1 = data.index(after: i)
            let next2 = next1 < data.endIndex ? data.index(after: next1) : data.endIndex
            let b1 = data[i]
            let b2 = next1 < data.endIndex ? data[next1] : 0
            let b3 = next2 < data.endIndex ? data[next2] : 0
            result.append(alphabet[Int(b1 >> 2)])
            result.append(alphabet[Int(((b1 & 0x3) << 4) | (b2 >> 4))])
            result.append(alphabet[Int(((b2 & 0xF) << 2) | (b3 >> 6))])
            result.append(alphabet[Int(b3 & 0x3F)])
            i = next2 < data.endIndex ? data.index(after: next2) : data.endIndex
        }
        return result
    }
}

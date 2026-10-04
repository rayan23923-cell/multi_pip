import Foundation
import TLFoundation

/// Lightweight check that data is a PowerPoint (.pptx) package, done at import.
///
/// It reads only the ZIP central directory: nothing is inflated, parsed or
/// rendered. A .pptx is a ZIP holding `[Content_Types].xml` and
/// `ppt/presentation.xml`. Anything else, a macro project, unsafe paths or
/// sizes that point to a ZIP bomb is rejected with
/// `TaskLensError.validationFailed(.invalidPresentation)`.
public enum PowerPointPackage {
    /// What the central directory says about a valid package.
    public struct Summary: Equatable, Sendable {
        public var entryCount: Int
        /// Parts named `ppt/slides/slideN.xml`. Unused parts count too, so this is not the shown slide count.
        public var slidePartCount: Int
        public var uncompressedSize: Int64
    }

    static let maximumEntries = 10_000
    static let maximumUncompressedSize: Int64 = 1 << 30
    /// An entry larger than this must not be compressed more than `maximumRatio` times.
    static let ratioCheckThreshold: Int64 = 50 * 1024 * 1024
    static let maximumRatio: Int64 = 100

    private static let localHeader: UInt32 = 0x0403_4B50
    private static let centralHeader: UInt32 = 0x0201_4B50
    private static let endOfDirectory: UInt32 = 0x0605_4B50

    @discardableResult
    public static func validate(_ data: Data) throws -> Summary {
        guard let summary = inspect(data) else {
            throw TaskLensError.validationFailed(.invalidPresentation)
        }
        return summary
    }

    static func inspect(_ data: Data) -> Summary? {
        // Reads in place: an imported file may be up to 200 MB and memory-mapped.
        data.withUnsafeBytes { inspect($0) }
    }

    private static func inspect(_ bytes: UnsafeRawBufferPointer) -> Summary? {
        guard bytes.count >= 22, read32(bytes, 0) == localHeader else { return nil }

        // The end-of-directory record sits in the last 22 bytes plus an optional comment.
        var end = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        while end >= lowest, read32(bytes, end) != endOfDirectory { end -= 1 }
        guard end >= lowest else { return nil }

        let disk = read16(bytes, end + 4), directoryDisk = read16(bytes, end + 6)
        let entries = Int(read16(bytes, end + 10))
        let directorySize = Int(read32(bytes, end + 12)), directoryOffset = Int(read32(bytes, end + 16))
        // Split archives and ZIP64 (over 65,535 entries or 4 GB) are not PowerPoint files TaskLens accepts.
        guard disk == 0, directoryDisk == 0, entries > 0, entries < 0xFFFF, entries <= maximumEntries,
              directoryOffset != 0xFFFF_FFFF, directoryOffset + directorySize <= end
        else { return nil }

        var names = Set<String>()
        var slideParts = 0
        var total: Int64 = 0
        var offset = directoryOffset
        for _ in 0..<entries {
            guard offset + 46 <= end, read32(bytes, offset) == centralHeader else { return nil }
            let compressed = Int64(read32(bytes, offset + 20))
            let uncompressed = Int64(read32(bytes, offset + 24))
            let nameLength = Int(read16(bytes, offset + 28))
            let extraLength = Int(read16(bytes, offset + 30))
            let commentLength = Int(read16(bytes, offset + 32))
            let nameEnd = offset + 46 + nameLength
            guard nameEnd <= end, let name = String(bytes: UnsafeRawBufferPointer(rebasing: bytes[(offset + 46)..<nameEnd]), encoding: .utf8) else { return nil }

            guard isSafe(name) else { return nil }
            total += uncompressed
            guard total <= maximumUncompressedSize else { return nil }
            if uncompressed > ratioCheckThreshold, uncompressed / max(compressed, 1) > maximumRatio { return nil }

            names.insert(name)
            if isSlidePart(name) { slideParts += 1 }
            offset = nameEnd + extraLength + commentLength
        }

        guard names.contains("[Content_Types].xml"), names.contains("ppt/presentation.xml"),
              // A macro project means a renamed .pptm.
              !names.contains("ppt/vbaProject.bin")
        else { return nil }
        return Summary(entryCount: entries, slidePartCount: slideParts, uncompressedSize: total)
    }

    private static func isSafe(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("/") && !name.contains("\\")
            && !name.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func isSlidePart(_ name: String) -> Bool {
        guard name.hasPrefix("ppt/slides/slide"), name.hasSuffix(".xml") else { return false }
        let number = name.dropFirst("ppt/slides/slide".count).dropLast(".xml".count)
        return !number.isEmpty && number.allSatisfy(\.isASCII) && number.allSatisfy(\.isNumber)
    }

    private static func read16(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func read32(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

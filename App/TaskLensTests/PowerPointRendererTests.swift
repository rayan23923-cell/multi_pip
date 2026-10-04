import CoreGraphics
import Foundation
import ImageIO
import Testing
import TLCoreServices
@_spi(Testing) import TLPowerPointRendering
import UIKit

/// A9.2: the offline WebKit renderer, on decks from `Fixtures/` (made by
/// `Tools/PPTXAudit/make_renderer_fixtures.py`). Runs in the app so WebKit has
/// a window scene. `PPTX` lines carry measurements; `PROBEIMG` lines carry
/// small JPEGs of chosen slides so they can be checked by eye from the log.
@MainActor
@Suite("PowerPoint renderer", .serialized)
struct PowerPointRendererTests {
    private let renderer = PowerPointRenderer()

    // MARK: Rendering

    @Test(arguments: [("scale-1", 1), ("scale-3", 3), ("scale-10", 10)])
    func rendersOneImagePerSlide(name: String, count: Int) async throws {
        try await withOutput { destination in
            let output = try await render(name, to: destination)
            #expect(output.slides.count == count)
            #expect(output.slides.map(\.index) == Array(1...count))
            #expect(try listing(destination) == (1...count).map { String(format: "slide-%03d.png", $0) })
            for slide in output.slides {
                #expect(slide.pixelWidth == 1920, "slide \(slide.index)")
                #expect(abs(slide.pixelHeight - 1080) <= 2, "slide \(slide.index)")
                #expect(try Pixels(slide.fileURL).distinctColors > 2, "slide \(slide.index) is blank")
            }
            #expect(output.diagnostics.externalRequestCount == 0)
        }
    }

    @Test func slidesComeOutInPresentationOrder() async throws {
        // Parts were created C, A, E, B, D; the presentation lists A–E.
        let expected: [(Int, Int, Int)] = [(220, 30, 30), (30, 160, 60), (30, 60, 220), (240, 200, 0), (120, 30, 160)]
        try await withOutput { destination in
            let output = try await render("order", to: destination)
            #expect(output.slides.map(\.source.part) == [2, 4, 1, 5, 3].map { "ppt/slides/slide\($0).xml" })
            #expect(output.slides.map(\.source.position) == [1, 2, 3, 4, 5])
            #expect(Set(output.slides.map(\.source.slideID)).count == 5)
            for (slide, color) in zip(output.slides, expected) {
                #expect(try Pixels(slide.fileURL).matches(color, atX: 0.95, y: 0.9), "slide \(slide.index)")
            }
            // Rendering again gives the same order and identities.
            try await withOutput { again in
                let second = try await render("order", to: again)
                #expect(second.slides.map(\.source) == output.slides.map(\.source))
            }
        }
    }

    @Test func hiddenSlidesAreSkipped() async throws {
        try await withOutput { destination in
            let output = try await render("hidden", to: destination)
            log("hidden webKitSlides=\(output.diagnostics.webKitSlideCount) of \(output.deck.slides.count)")
            #expect(output.slides.map(\.source.position) == [1, 3])
            #expect(try listing(destination) == ["slide-001.png", "slide-002.png"])
            #expect(try Pixels(output.slides[0].fileURL).matches((220, 30, 30), atX: 0.95, y: 0.9))
            #expect(try Pixels(output.slides[1].fileURL).matches((30, 60, 220), atX: 0.95, y: 0.9))
        }
    }

    @Test(arguments: [("aspect-4x3", 4.0 / 3.0), ("aspect-square", 1.0)])
    func slideSizeFollowsTheDeck(name: String, ratio: Double) async throws {
        try await withOutput { destination in
            let output = try await render(name, to: destination)
            let slide = try #require(output.slides.first)
            log("\(name) pixels=\(slide.pixelWidth)x\(slide.pixelHeight) webKit=\(output.diagnostics.webKitSlideSize)")
            #expect(abs(Double(slide.pixelWidth) / Double(slide.pixelHeight) - ratio) < 0.01)
            #expect(max(slide.pixelWidth, slide.pixelHeight) == 1920)
            let pixels = try Pixels(slide.fileURL)
            #expect(pixels.matches((30, 60, 220), atX: 0.03, y: 0.03), "background corner")
            #expect(pixels.matches((30, 60, 220), atX: 0.97, y: 0.97), "background corner")
            #expect(pixels.matches((255, 255, 255), atX: 0.5, y: 0.75), "frame inside")
            emit("\(name)", slide.fileURL, width: 480)
        }
    }

    @Test func auditDeckRendersEveryKindOfContent() async throws {
        // Text, fonts, pictures, shapes, table, chart, background, layout, Arabic,
        // mixed text, a 4000×2250 picture, long text, 40 objects, complex layout.
        try await withOutput { destination in
            let output = try await render("audit-15", to: destination)
            #expect(output.slides.count == 15)
            for slide in output.slides {
                #expect(try Pixels(slide.fileURL).distinctColors > 2, "slide \(slide.index) is blank")
                emit("audit-\(slide.index)", slide.fileURL, width: 480)
            }
            log("audit-15 brokenImages=\(output.diagnostics.brokenImageCount) bytes=\(output.diagnostics.totalBytes)")
            #expect(output.diagnostics.brokenImageCount == 0)
        }
    }

    @Test func arabicKeepsItsDirection() async throws {
        try await withOutput { destination in
            let output = try await render("arabic", to: destination)
            #expect(output.slides.count == 4)
            #expect(output.diagnostics.directionFixApplied)
            for slide in output.slides { emit("arabic-\(slide.index)", slide.fileURL, width: 960) }
        }
    }

    @Test func otherFileNamesAreRenderedToo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RendererTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let renamed = folder.appendingPathComponent("Deck")
        try FileManager.default.copyItem(at: try fixture("order"), to: renamed)
        try await withOutput { destination in
            let output = try await renderer.render(renamed, to: destination)
            #expect(output.slides.count == 5)
        }
    }

    @Test func rendersAreOneAtATime() async throws {
        let order = try fixture("order"), three = try fixture("scale-3")
        try await withOutput { first in
            try await withOutput { second in
                async let a = renderer.render(order, to: first)
                async let b = renderer.render(three, to: second)
                let (one, two) = try await (a, b)
                #expect(one.slides.count == 5)
                #expect(two.slides.count == 3)
            }
        }
        #expect(PowerPointRenderer.peakWebViewCount == 1)
        #expect(PowerPointRenderer.liveWebViewCount == 0)
    }

    // MARK: Security

    @Test func externalPictureIsNeverFetched() async throws {
        try await withOutput { destination in
            let output = try await render("external", to: destination)
            #expect(output.deck.externalResourceCount == 1)
            #expect(output.slides.count == 1)
            #expect(output.diagnostics.externalRequestCount == 0)
            log("external blockedNavigations=\(output.diagnostics.blockedNavigationCount) brokenImages=\(output.diagnostics.brokenImageCount)")
        }
    }

    nonisolated static let hostileFiles: [(String, Data)] = [
        ("not a ZIP", Data("This is not a presentation.".utf8)),
        ("macro project", MiniZip.make([("[Content_Types].xml", "<x/>"), ("ppt/presentation.xml", "<x/>"), ("ppt/vbaProject.bin", "x")])),
        ("path escaping the package", MiniZip.make([("[Content_Types].xml", "<x/>"), ("ppt/presentation.xml", "<x/>"), ("../evil.xml", "x")])),
        ("entity in presentation", MiniZip.make([
            ("[Content_Types].xml", "<x/>"),
            ("ppt/presentation.xml", #"<?xml version="1.0"?><!DOCTYPE p [<!ENTITY x SYSTEM "file:///etc/hosts">]><p:presentation>&x;</p:presentation>"#),
        ])),
        ("Word file renamed", MiniZip.make([("[Content_Types].xml", "<x/>"), ("word/document.xml", "<x/>")])),
    ]

    @Test(arguments: hostileFiles.indices)
    func hostileFileIsRefusedBeforeWebKit(index: Int) async throws {
        let (label, data) = Self.hostileFiles[index]
        try await expectFailure(.invalidPresentation, data: data, label)
    }

    @Test func corruptDeckIsRefused() async throws {
        let data = try Data(contentsOf: try fixture("order"))
        try await expectFailure(.invalidPresentation, data: data.prefix(data.count / 2), "cut in half")
    }

    // MARK: Failures

    @Test func missingSlideIsAMissingResource() async throws {
        try await expectFailure(.resourceMissing(part: "ppt/slides/slide2.xml"), file: try fixture("missing-slide"))
    }

    @Test func deckWithSpeakerNotesRendersOrFailsCleanly() async throws {
        for name in ["audit-with-notes", "libreoffice-resave"] {
            let leftovers = temporaryRenders()
            try await withOutput { destination in
                do {
                    let output = try await render(name, to: destination)
                    log("\(name) rendered \(output.slides.count) slides")
                    #expect(output.slides.count == 15)
                } catch let error as PowerPointRenderError {
                    log("\(name) refused \(error) webKit=\(PowerPointRenderer.lastFailureDetail ?? "-")")
                    #expect(error == .unsupportedContent, "\(name)")
                    #expect(!FileManager.default.fileExists(atPath: destination.path))
                }
            }
            #expect(temporaryRenders() == leftovers)
        }
    }

    @Test func timeoutStopsAndCleansUp() async throws {
        try await expectFailure(.timeout, file: try fixture("scale-100"), options: .init(timeout: .milliseconds(1)))
    }

    @Test func cancellationStopsAndCleansUp() async throws {
        let leftovers = temporaryRenders()
        try await withOutput { destination in
            let url = try fixture("scale-100")
            let task = Task { try await renderer.render(url, to: destination) }
            try await Task.sleep(for: .milliseconds(400))
            task.cancel()
            let result = await task.result
            #expect(throws: PowerPointRenderError.cancelled) { try result.get() }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
        #expect(temporaryRenders() == leftovers)
        #expect(PowerPointRenderer.liveWebViewCount == 0)
    }

    @Test func webViewFailureCleansUp() async throws {
        var options = PowerPointRenderer.Options()
        options.simulatesWebViewFailure = true
        try await expectFailure(.webViewFailed, file: try fixture("scale-1"), options: options)
        log("webViewFailure webKit=\(PowerPointRenderer.lastFailureDetail ?? "-")")
    }

    @Test func existingDestinationIsNeverOverwritten() async throws {
        try await withOutput { destination in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let marker = destination.appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: marker)
            await #expect(throws: PowerPointRenderError.renderingFailed(.writeFailed)) {
                try await render("scale-1", to: destination)
            }
            #expect(try listing(destination) == ["keep.txt"])
        }
    }

    // MARK: Performance

    @Test func performance() async throws {
        let runs: [(String, PowerPointRenderer.ImageFormat)] = [
            ("scale-10", .png), ("scale-50", .png), ("scale-100", .png), ("scale-100", .jpeg(quality: 0.85)),
        ]
        for (name, format) in runs {
            let before = peakResidentMB()
            try await withOutput { destination in
                let output = try await render(name, to: destination, options: .init(format: format))
                let d = output.diagnostics
                let count = output.slides.count
                log(String(format: "PERF %@ %@ slides=%d total=%.2fs load=%.2fs snapshots=%.2fs perSlide=%.3fs storage=%.1fMB peakRSS=%.0fMB (+%.0f)",
                           name, format == .png ? "png" : "jpeg", count, d.totalSeconds, d.loadSeconds, d.snapshotSeconds,
                           d.snapshotSeconds / Double(max(count, 1)), Double(d.totalBytes) / 1_048_576,
                           peakResidentMB(), peakResidentMB() - before))
                #expect(count == Int(name.dropFirst("scale-".count)))
                #expect(try Pixels(output.slides[count - 1].fileURL).distinctColors > 2)
            }
        }
    }

    // MARK: Helpers

    /// Renders a fixture, logging why when it fails.
    private func render(_ name: String, to destination: URL, options: PowerPointRenderer.Options = .init()) async throws
        -> PowerPointRenderer.Output {
        do {
            return try await renderer.render(try fixture(name), to: destination, options: options)
        } catch {
            log("\(name) failed \(error) detail=\(PowerPointRenderer.lastFailureDetail ?? "-")")
            throw error
        }
    }

    private func expectFailure(_ expected: PowerPointRenderError, data: Data, _ label: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RendererTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Deck.pptx")
        try data.write(to: file)
        try await expectFailure(expected, file: file, label)
    }

    private func expectFailure(_ expected: PowerPointRenderError, file: URL, options: PowerPointRenderer.Options = .init(),
                               _ label: String = "") async throws {
        let leftovers = temporaryRenders()
        try await withOutput { destination in
            await #expect(throws: expected, "\(label)") {
                try await renderer.render(file, to: destination, options: options)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path), "\(label)")
        }
        #expect(temporaryRenders() == leftovers, "\(label)")
        #expect(PowerPointRenderer.liveWebViewCount == 0)
    }

    private func withOutput(_ body: (URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RendererTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try await body(folder.appendingPathComponent("Slides"))
    }

    private func fixture(_ name: String) throws -> URL {
        let bundle = Bundle(for: FixtureToken.self)
        let url = bundle.url(forResource: name, withExtension: "pptx")
            ?? bundle.url(forResource: name, withExtension: "pptx", subdirectory: "Fixtures")
        return try #require(url, "fixture \(name)")
    }

    private func listing(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func temporaryRenders() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("PowerPointRender-") })
    }

    private func peakResidentMB() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576
    }

    private func log(_ line: String) { print("PPTX \(line)") }

    /// Prints a small JPEG of the image, base64 in 8,000-character lines.
    private func emit(_ name: String, _ url: URL, width: CGFloat) {
        guard let image = UIImage(contentsOfFile: url.path) else { return }
        let scale = min(1, width / max(image.size.width * image.scale, 1))
        let size = CGSize(width: image.size.width * image.scale * scale, height: image.size.height * image.scale * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let encoded = resized.jpegData(compressionQuality: 0.7)?.base64EncodedString() else { return }
        let parts = stride(from: 0, to: encoded.count, by: 8000).map { start in
            let from = encoded.index(encoded.startIndex, offsetBy: start)
            return String(encoded[from..<encoded.index(from, offsetBy: min(8000, encoded.count - start))])
        }
        for (index, part) in parts.enumerated() { print("PROBEIMG \(name) \(index)/\(parts.count) \(part)") }
    }
}

private final class FixtureToken {}

/// An image's pixels as 8-bit sRGB, top row first.
private struct Pixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ url: URL) throws {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(drawn)
        self.width = width
        self.height = height
        bytes = buffer
    }

    func color(atX x: Double, y: Double) -> (Int, Int, Int) {
        let column = min(width - 1, Int(Double(width) * x)), row = min(height - 1, Int(Double(height) * y))
        let offset = (row * width + column) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    func matches(_ expected: (Int, Int, Int), atX x: Double, y: Double, tolerance: Int = 40) -> Bool {
        let actual = color(atX: x, y: y)
        return abs(actual.0 - expected.0) <= tolerance && abs(actual.1 - expected.1) <= tolerance
            && abs(actual.2 - expected.2) <= tolerance
    }

    /// Colors on a 40×40 grid, rounded to 16 levels; 1 means a blank image.
    var distinctColors: Int {
        var seen = Set<Int>()
        for row in 0..<40 {
            for column in 0..<40 {
                let (r, g, b) = color(atX: Double(column) / 40, y: Double(row) / 40)
                seen.insert((r / 16) << 8 | (g / 16) << 4 | b / 16)
            }
        }
        return seen.count
    }
}

/// Stored (uncompressed) ZIP archives for hostile files.
private enum MiniZip {
    static func make(_ entries: [(String, String)]) -> Data {
        var body = Data(), directory = Data()
        for (name, text) in entries {
            let nameData = Data(name.utf8), data = Data(text.utf8)
            let offset = UInt32(body.count), size = UInt32(data.count)
            body.append(join([le32(0x0403_4B50), le16(20), le16(0), le16(0), le16(0), le16(0), le32(0), le32(size), le32(size),
                              le16(UInt16(nameData.count)), le16(0), nameData, data]))
            directory.append(join([le32(0x0201_4B50), le16(20), le16(20), le16(0), le16(0), le16(0), le16(0), le32(0),
                                   le32(size), le32(size), le16(UInt16(nameData.count)), le16(0), le16(0), le16(0), le16(0),
                                   le32(0), le32(offset), nameData]))
        }
        let end = join([le32(0x0605_4B50), le16(0), le16(0), le16(UInt16(entries.count)), le16(UInt16(entries.count)),
                        le32(UInt32(directory.count)), le32(UInt32(body.count)), le16(0)])
        return join([body, directory, end])
    }

    private static func join(_ parts: [Data]) -> Data { parts.reduce(into: Data()) { $0.append($1) } }
    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}

import Compression
import Foundation
import Testing
import TLCoreServices
import TLDomain
import TLFoundation
import UniformTypeIdentifiers

/// Builds ZIP archives, stored or (per entry) deflated. Declared sizes can be overridden to imitate a ZIP bomb.
enum TestZip {
    struct Entry {
        var name: String
        var data: Data
        var declaredCompressed: UInt32?
        var declaredUncompressed: UInt32?
        var deflated = false

        init(_ name: String, _ text: String = "<x/>", declaredCompressed: UInt32? = nil, declaredUncompressed: UInt32? = nil,
             deflated: Bool = false) {
            self.name = name
            self.data = Data(text.utf8)
            self.declaredCompressed = declaredCompressed
            self.declaredUncompressed = declaredUncompressed
            self.deflated = deflated
        }
    }

    /// Raw DEFLATE, as ZIP method 8 stores it.
    static func deflate(_ data: Data) -> Data {
        var output = Data(count: data.count + 1024)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
                                          source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return output.prefix(written)
    }

    static func make(_ entries: [Entry]) -> Data {
        var body = Data(), directory = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let offset = UInt32(body.count)
            let stored = entry.deflated ? deflate(entry.data) : entry.data
            let method: UInt16 = entry.deflated ? 8 : 0
            let compressed = entry.declaredCompressed ?? UInt32(stored.count)
            let uncompressed = entry.declaredUncompressed ?? UInt32(entry.data.count)
            body += join([le32(0x0403_4B50), le16(20), le16(0), le16(method), le16(0), le16(0), le32(0),
                          le32(UInt32(stored.count)), le32(UInt32(entry.data.count)),
                          le16(UInt16(name.count)), le16(0), name, stored])
            directory += join([le32(0x0201_4B50), le16(20), le16(20), le16(0), le16(method), le16(0), le16(0), le32(0),
                               le32(compressed), le32(uncompressed), le16(UInt16(name.count)), le16(0), le16(0),
                               le16(0), le16(0), le32(0), le32(offset), name])
        }
        let end = join([le32(0x0605_4B50), le16(0), le16(0), le16(UInt16(entries.count)), le16(UInt16(entries.count)),
                         le32(UInt32(directory.count)), le32(UInt32(body.count)), le16(0)])
        return body + directory + end
    }

    /// The smallest package TaskLens accepts as a .pptx, with `slides` slide parts.
    static func powerPoint(slides: Int = 2, extra: [Entry] = []) -> Data {
        make([Entry("[Content_Types].xml"), Entry("_rels/.rels"), Entry("ppt/presentation.xml")]
            + (1...max(slides, 1)).map { Entry("ppt/slides/slide\($0).xml") } + extra)
    }

    private static func join(_ parts: [Data]) -> Data { parts.reduce(into: Data()) { $0.append($1) } }
    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}

@Suite("PowerPoint import")
struct PowerPointImportTests {
    private let env = TestEnvironment()

    private func storedFiles(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Documents").path)) ?? []
    }

    // MARK: Detection

    @Test func pptxIsRecognizedAsAPowerPointPresentation() async throws {
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = env.documents(in: directory)
        do {
            let document = try await service.importData(TestZip.powerPoint(), filename: "Quarterly Review.pptx", contentType: nil)
            #expect(document.kind == .powerpoint)
            #expect(document.file.contentType == "org.openxmlformats.presentationml.presentation")
            #expect(document.title == "Quarterly Review")
            #expect(document.file.originalFilename == "Quarterly Review.pptx")
            #expect(document.file.relativePath.hasSuffix(".pptx"))
            #expect(FileManager.default.fileExists(atPath: service.fileURL(for: document).path))
            #expect(try await service.documents(in: nil).map(\.id) == [document.id])

            // The type the file picker reports gives the same result.
            let picked = try await service.importData(TestZip.powerPoint(), filename: "Deck", contentType: DocumentService.powerPoint)
            #expect(picked.kind == .powerpoint)
            #expect(storedFiles(in: directory).count == 2)
        }
    }

    @Test func pptxImportsFromAFileLikeOtherDocuments() async throws {
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = env.documents(in: directory)
        do {
            let source = directory.appendingPathComponent("Pitch.pptx")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try TestZip.powerPoint().write(to: source)
            let document = try await service.importFile(at: source)
            #expect(document.kind == .powerpoint)
            try await service.delete(document.id)
            #expect(!FileManager.default.fileExists(atPath: service.fileURL(for: document).path))
        }
    }

    @Test func typeMapping() {
        #expect(DocumentService.kind(for: DocumentService.powerPoint) == .powerpoint)
        #expect(UTType(filenameExtension: "pptx").flatMap(DocumentService.kind(for:)) == .powerpoint)
        #expect(DocumentService.importableTypes.contains(DocumentService.powerPoint))
        // The older binary format and Keynote are different types and stay unsupported.
        #expect(UTType(filenameExtension: "ppt").flatMap(DocumentService.kind(for:)) == nil)
        #expect(UTType(filenameExtension: "key").flatMap(DocumentService.kind(for:)) == nil)
        #expect(DocumentService.kind(for: .zip) == nil)
        // Nothing else moved.
        #expect(DocumentService.kind(for: .pdf) == .pdf)
        #expect(DocumentService.kind(for: .png) == .image)
        #expect(DocumentService.kind(for: .jpeg) == .image)
        #expect(DocumentService.kind(for: .plainText) == .text)
        #expect(DocumentService.kind(for: .json) == .text)
    }

    @Test func packageSummaryReadsOnlyTheDirectory() throws {
        let summary = try PowerPointPackage.validate(TestZip.powerPoint(slides: 3, extra: [TestZip.Entry("ppt/slides/_rels/slide1.xml.rels")]))
        #expect(summary.slidePartCount == 3)
        #expect(summary.entryCount == 7)
    }

    // MARK: Rejection

    static let invalidFiles: [(String, Data)] = [
        ("not a ZIP", Data("This is not a PowerPoint file.".utf8)),
        ("PDF renamed .pptx", Data("%PDF-1.4\n1 0 obj << >> endobj\n%%EOF".utf8)),
        ("Word file renamed .pptx", TestZip.make([TestZip.Entry("[Content_Types].xml"), TestZip.Entry("word/document.xml")])),
        ("ZIP without content types", TestZip.make([TestZip.Entry("ppt/presentation.xml")])),
        ("macro project (.pptm renamed)", TestZip.powerPoint(extra: [TestZip.Entry("ppt/vbaProject.bin")])),
        ("path escaping the package", TestZip.powerPoint(extra: [TestZip.Entry("../outside.xml")])),
        ("absolute path", TestZip.powerPoint(extra: [TestZip.Entry("/etc/hosts")])),
        ("ZIP bomb ratio", TestZip.powerPoint(extra: [
            TestZip.Entry("ppt/media/huge.bin", declaredCompressed: 300_000, declaredUncompressed: 300_000_000),
        ])),
        ("ZIP bomb total", TestZip.powerPoint(extra: (1...3).map {
            TestZip.Entry("ppt/media/big\($0).bin", declaredCompressed: 400_000_000, declaredUncompressed: 400_000_000)
        })),
        ("cut short", TestZip.powerPoint().dropLast(30)),
        ("only the local header", Data(TestZip.powerPoint().prefix(30))),
    ]

    @Test(arguments: invalidFiles.indices)
    func invalidPowerPointIsRejectedAndNothingIsKept(index: Int) async throws {
        let (label, data) = Self.invalidFiles[index]
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = env.documents(in: directory)
        do {
            await #expect(throws: TaskLensError.validationFailed(.invalidPresentation), "\(label)") {
                try await service.importData(data, filename: "Deck.pptx", contentType: nil)
            }
            #expect(try await service.documents(in: nil).isEmpty, "\(label)")
            #expect(storedFiles(in: directory).isEmpty, "\(label)")
        }
    }

    @Test func emptyPowerPointIsEmptyContent() async throws {
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = env.documents(in: directory)
        do {
            await #expect(throws: TaskLensError.validationFailed(.emptyContent)) {
                try await service.importData(Data(), filename: "Deck.pptx", contentType: nil)
            }
        }
    }

    @Test func otherFormatsAreUnaffected() async throws {
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = env.documents(in: directory)
        do {
            // A real PowerPoint package named .pdf is still treated as a PDF, as before A9.
            #expect(try await service.importData(TestZip.powerPoint(), filename: "a.pdf", contentType: nil).kind == .pdf)
            #expect(try await service.importData(Data([1]), filename: "b.png", contentType: nil).kind == .image)
            #expect(try await service.importData(Data("x".utf8), filename: "c.txt", contentType: nil).kind == .text)
            await #expect(throws: TaskLensError.unsupportedContent(type: "unknown")) {
                try await service.importData(Data([1]), filename: "d.ppt", contentType: nil)
            }
        }
    }

    // MARK: Elsewhere in the engine

    @Test func powerPointIsADocumentForContextAndWorkflows() {
        let file = FileReference(relativePath: "Deck.pptx", originalFilename: "Deck.pptx",
                                 contentType: DocumentService.powerPoint.identifier, kind: .powerpoint, byteCount: 10)
        #expect(ContextContent.file(file).itemType == .document)
        #expect(WorkflowService.triggers(for: ContextContent.file(file)).isEmpty)
    }
}

import Foundation
import Testing
import TLCoreServices
import TLDomain
import TLFoundation
import UniformTypeIdentifiers

/// Exercises the share pipeline with real `NSItemProvider`s, the same objects
/// the share sheet hands to the extension.
@MainActor
@Suite("Share intake")
struct ShareIntakeTests {
    private func makeFile(_ name: String, bytes: Int, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x25, count: bytes).write(to: url)
        return url
    }

    @Test func loadsTextLinksAndFilesInOrder() async throws {
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = try makeFile("Report.pdf", bytes: 1_024, in: directory.appendingPathComponent("source"))
        let image = try makeFile("Photo.png", bytes: 2_048, in: directory.appendingPathComponent("source"))

        let providers = [
            NSItemProvider(object: "Call +964 770 123 4567" as NSString),
            NSItemProvider(object: URL(string: "https://example.com/item")! as NSURL),
            try #require(NSItemProvider(contentsOf: pdf)),
            try #require(NSItemProvider(contentsOf: image)),
        ]
        let intake = directory.appendingPathComponent("intake")
        let attachments = await ShareIntake.load(providers, into: intake)

        #expect(attachments.count == 4)
        guard case .text(let text) = attachments[0].payload else { Issue.record("expected text"); return }
        #expect(text == "Call +964 770 123 4567")
        guard case .url(let url) = attachments[1].payload else { Issue.record("expected url"); return }
        #expect(url.absoluteString == "https://example.com/item")
        guard case .file(let pdfCopy, let pdfType, let pdfName, let pdfSize) = attachments[2].payload else {
            Issue.record("expected pdf"); return
        }
        #expect(pdfType.conforms(to: .pdf))
        #expect(pdfName.hasSuffix(".pdf"))
        #if os(iOS)
        // The macOS host's in-process providers rename files; iOS keeps the name.
        #expect(pdfName == "Report.pdf")
        #endif
        #expect(pdfSize == 1_024)
        #expect(pdfCopy.path.hasPrefix(intake.path))
        #expect(FileManager.default.fileExists(atPath: pdfCopy.path))
        guard case .file(_, let imageType, _, _) = attachments[3].payload else { Issue.record("expected image"); return }
        #expect(imageType.conforms(to: .image))
    }

    @Test func unsupportedItemsDoNotFailTheShare() async throws {
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unknown = NSItemProvider(item: Data([1, 2, 3]) as NSData, typeIdentifier: "com.example.unknown-thing")
        let empty = NSItemProvider(object: "   " as NSString)
        let attachments = await ShareIntake.load([unknown, empty, NSItemProvider(object: "ok" as NSString)], into: directory)

        #expect(attachments.map(\.isSupported) == [false, false, true])
        if case .unsupported(let reason, let types) = attachments[0].payload {
            #expect(reason == .type)
            #expect(types == ["com.example.unknown-thing"])
        } else {
            Issue.record("expected unsupported")
        }
    }

    @Test func limitsTheNumberOfItems() async throws {
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let providers = (0..<(ShareIntake.maximumAttachments + 2)).map { NSItemProvider(object: "item \($0)" as NSString) }
        let attachments = await ShareIntake.load(providers, into: directory)
        #expect(attachments.count == ShareIntake.maximumAttachments + 2)
        #expect(attachments.filter(\.isSupported).count == ShareIntake.maximumAttachments)
        if case .unsupported(let reason, _) = attachments.last?.payload {
            #expect(reason == .tooMany)
        }
    }

    @Test func cancellationStopsLoading() async throws {
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let providers = (0..<5).map { NSItemProvider(object: "item \($0)" as NSString) }
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await ShareIntake.load(providers, into: directory)
        }
        #expect(await task.value.isEmpty)
    }

    /// Share extensions are killed above roughly 120 MB. Files must be streamed
    /// to disk, never read into memory.
    ///
    /// Measured on iOS only: on the macOS host, in-process item providers
    /// materialize the file themselves before TaskLens sees it.
    @Test(.enabled(if: isIOS)) func largeFilesAreStreamedNotLoadedIntoMemory() async throws {
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let big = source.appendingPathComponent("Scan.pdf")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        let chunk = Data(repeating: 0x20, count: 1 << 20)
        for _ in 0..<80 { try handle.write(contentsOf: chunk) }
        try handle.close()

        let before = MemoryFootprint.current()
        let attachments = await ShareIntake.load([try #require(NSItemProvider(contentsOf: big))],
                                                 into: directory.appendingPathComponent("intake"))
        let growth = MemoryFootprint.current() - before

        guard case .file(let copy, _, _, let size) = attachments.first?.payload else {
            Issue.record("expected a file"); return
        }
        #expect(size == 80 << 20)
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(growth < 40 << 20, "Memory grew by \(growth >> 20) MB while sharing an 80 MB file")
    }

    @Test func previewsRunTheContextAndActionEngines() {
        let phone = ShareService.preview(for: SharedAttachment(payload: .text("+964 770 123 4567")))
        #expect(phone.analysis.category == .phone)
        #expect(phone.analysis.actions.first?.type == .call)

        let link = ShareService.preview(for: SharedAttachment(payload: .text("https://example.com")))
        #expect(link.content == .url(URL(string: "https://example.com")!))
        #expect(link.analysis.category == .url)

        let file = ShareService.preview(for: SharedAttachment(payload: .file(
            URL(fileURLWithPath: "/tmp/x.pdf"), type: .pdf, filename: "x.pdf", byteCount: 10
        )))
        #expect(file.analysis.category == .pdf)
        #expect(file.analysis.actions.first?.type == .saveToSession)

        let unsupported = ShareService.preview(for: SharedAttachment(payload: .unsupported(.type, typeIdentifiers: [])))
        #expect(!unsupported.isSupported)
        #expect(unsupported.analysis.actions.isEmpty)
    }

    @Test func savesSupportedItemsIntoSession() async throws {
        let env = TestEnvironment(detector: ContextEngine())
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documents = env.documents(in: directory.appendingPathComponent("Files"))
        let service = ShareService(capture: env.capture, documents: documents)
        let workspace = try await env.workspaces.create(name: "Trip", kind: .shopping)
        let session = try await env.sessions.start(in: workspace.id)

        let pdf = try makeFile("Ticket.pdf", bytes: 64, in: directory.appendingPathComponent("source"))
        let attachments = await ShareIntake.load([
            NSItemProvider(object: "$25.99" as NSString),
            try #require(NSItemProvider(contentsOf: pdf)),
            NSItemProvider(item: Data([1]) as NSData, typeIdentifier: "com.example.unknown-thing"),
        ], into: directory.appendingPathComponent("intake"))
        let previews = attachments.map(ShareService.preview(for:))

        let items = try await service.save(previews, into: session.id, workspaceID: workspace.id)
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.source == .shareExtension && $0.sessionID == session.id })
        #expect(items[0].entities.first?.type == .currencyAmount)
        #expect(items[0].metadata["category"] == .string("currency"))
        #expect(items[1].type == .pdf)
        let stored = try await documents.documents(in: workspace.id)
        #expect(stored.count == 1)
        #if os(iOS)
        #expect(stored.map(\.title) == ["Ticket"])
        #endif
    }
}

/// Peak resident memory of this process (bytes on Apple platforms). A file
/// read into memory would raise the peak by its size.
#if os(iOS)
let isIOS = true
#else
let isIOS = false
#endif

enum MemoryFootprint {
    static func current() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Int64(usage.ru_maxrss)
    }
}

/// The extension hands shares to the app through the outbox instead of
/// writing the app's store directly.
@MainActor
@Suite("Share outbox")
struct ShareOutboxTests {
    private func setUp() async throws -> (TestEnvironment, ShareService, DocumentService, URL) {
        let env = TestEnvironment(detector: ContextEngine())
        let directory = TemporaryDirectory.make()
        let documents = env.documents(in: directory.appendingPathComponent("Files"))
        return (env, ShareService(capture: env.capture, documents: documents), documents, directory)
    }

    @Test func deliversQueuedSharesIntoTheChosenSession() async throws {
        let (env, service, documents, directory) = try await setUp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try await env.workspaces.create(name: "Trip")
        let session = try await env.sessions.start(in: workspace.id)

        let source = directory.appendingPathComponent("intake")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let pdf = source.appendingPathComponent("copy.pdf")
        try Data(repeating: 1, count: 32).write(to: pdf)

        let outbox = ShareOutbox(storeRoot: directory)
        let queued = try outbox.enqueue([
            SharedAttachment(payload: .text("+964 770 123 4567")),
            SharedAttachment(payload: .url(URL(string: "https://example.com")!)),
            SharedAttachment(payload: .file(pdf, type: .pdf, filename: "Ticket.pdf", byteCount: 32)),
            SharedAttachment(payload: .unsupported(.type, typeIdentifiers: ["x"])),
        ], sessionID: session.id)
        #expect(queued == 3)
        #expect(!FileManager.default.fileExists(atPath: pdf.path), "Files are moved, not copied")
        #expect(outbox.pendingEnvelopes().count == 1)

        let items = await outbox.deliver(using: service, sessions: env.sessions)
        #expect(items.map(\.type) == [.text, .url, .pdf])
        #expect(items.allSatisfy { $0.sessionID == session.id && $0.source == .shareExtension })
        #expect(items[0].entities.first?.type == .phoneNumber)
        #expect(try await documents.documents(in: workspace.id).map(\.title) == ["Ticket"])
        #expect(outbox.pendingEnvelopes().isEmpty)

        // Delivering again does nothing.
        #expect(await outbox.deliver(using: service, sessions: env.sessions).isEmpty)
    }

    @Test func endedSessionFallsBackToInbox() async throws {
        let (env, service, _, directory) = try await setUp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try await env.workspaces.create(name: "W")
        let session = try await env.sessions.start(in: workspace.id)
        let outbox = ShareOutbox(storeRoot: directory)
        try outbox.enqueue([SharedAttachment(payload: .text("note"))], sessionID: session.id)
        _ = try await env.sessions.end(session.id)

        let items = await outbox.deliver(using: service, sessions: env.sessions)
        #expect(items.count == 1)
        #expect(items.first?.sessionID == nil)
        #expect(try await env.capture.inboxItems().count == 1)
    }

    @Test func ignoresUnfinishedAndCorruptEnvelopes() async throws {
        let (env, service, _, directory) = try await setUp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = ShareOutbox(storeRoot: directory)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outbox.directory.appendingPathComponent(".pending.tmp"), withIntermediateDirectories: true)
        let corrupt = outbox.directory.appendingPathComponent("corrupt")
        try fileManager.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: corrupt.appendingPathComponent("manifest.json"))

        #expect(outbox.pendingEnvelopes().count == 1)
        #expect(await outbox.deliver(using: service, sessions: env.sessions).isEmpty)
        #expect(!fileManager.fileExists(atPath: corrupt.path))
        #expect(try await env.capture.inboxItems().isEmpty)
    }

    @Test func nothingSupportedWritesNothing() throws {
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = ShareOutbox(storeRoot: directory)
        #expect(try outbox.enqueue([SharedAttachment(payload: .unsupported(.tooLarge, typeIdentifiers: []))], sessionID: nil) == 0)
        #expect(outbox.pendingEnvelopes().isEmpty)
    }
}

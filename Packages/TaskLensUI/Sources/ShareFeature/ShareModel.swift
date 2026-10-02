import CoreGraphics
import Foundation
import ImageIO
import Observation
import TLCoreServices
import TLDomain
import TLLocalization
import UniformTypeIdentifiers

/// State of the share sheet: load what was shared, show what TaskLens
/// understood, then hand it to the app through the outbox.
///
/// Built to stay small inside the extension: files are streamed to disk,
/// images are shown as small ImageIO thumbnails, and the temporary folder is
/// removed on save and on cancel.
@MainActor
@Observable
public final class ShareModel {
    public enum Phase: Equatable, Sendable {
        case loading
        case ready
        case saving
        case saved(count: Int)
    }

    public enum Outcome: Equatable, Sendable {
        case saved(count: Int)
        case cancelled
    }

    public private(set) var phase: Phase = .loading
    public private(set) var previews: [ShareService.Preview] = []
    public private(set) var sessions: [Session] = []
    public private(set) var thumbnails: [UUID: CGImage] = [:]
    /// nil saves to the inbox.
    public var selectedSessionID: SessionID?
    public var errorMessage: String?
    /// Called once, when the sheet should close.
    public var onFinish: ((Outcome) -> Void)?

    @ObservationIgnored private let providers: [NSItemProvider]
    private let workingDirectory: URL
    private let outbox: ShareOutbox
    private let sessionService: SessionService?
    private let confirmationDelay: Duration
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var hasFinished = false

    public static let thumbnailPixelSize = 240

    public init(
        providers: [NSItemProvider],
        workingDirectory: URL,
        outbox: ShareOutbox,
        sessionService: SessionService?,
        confirmationDelay: Duration = .milliseconds(900)
    ) {
        self.providers = providers
        self.workingDirectory = workingDirectory
        self.outbox = outbox
        self.sessionService = sessionService
        self.confirmationDelay = confirmationDelay
    }

    public var supportedCount: Int { previews.filter(\.isSupported).count }
    public var canSave: Bool { phase == .ready && supportedCount > 0 }

    /// Starts loading in the background; `cancel()` stops it.
    public func start() {
        guard loadTask == nil else { return }
        loadTask = Task { [weak self] in await self?.load() }
    }

    /// Waits for the loading started by `start()`.
    public func waitUntilLoaded() async {
        await loadTask?.value
    }

    func load() async {
        let attachments = await ShareIntake.load(providers, into: workingDirectory)
        guard !Task.isCancelled else {
            // Anything copied before the cancel is discarded.
            removeWorkingDirectory()
            return
        }
        previews = attachments.map(ShareService.preview(for:))
        for preview in previews {
            if case .file(let url, let type, _, _) = preview.attachment.payload, type.conforms(to: .image),
               let thumbnail = Self.thumbnail(of: url) {
                thumbnails[preview.id] = thumbnail
            }
        }
        // The extension only reads the store, to list sessions. It never writes it.
        sessions = (try? await sessionService?.activeSessions()) ?? []
        selectedSessionID = sessions.first?.id
        phase = .ready
    }

    public func save() async {
        guard canSave else { return }
        phase = .saving
        let attachments = previews.map(\.attachment)
        let outbox = outbox
        let sessionID = selectedSessionID
        do {
            let count = try await Task.detached(priority: .userInitiated) {
                try outbox.enqueue(attachments, sessionID: sessionID)
            }.value
            phase = .saved(count: count)
            removeWorkingDirectory()
            if confirmationDelay > .zero {
                try? await Task.sleep(for: confirmationDelay)
            }
            finish(.saved(count: count))
        } catch {
            phase = .ready
            errorMessage = L10n.string(.shareSaveFailed)
        }
    }

    public func cancel() {
        loadTask?.cancel()
        removeWorkingDirectory()
        finish(.cancelled)
    }

    public func sessionTitle(_ session: Session) -> String {
        session.title ?? L10n.string(.sessionUntitled)
    }

    private func finish(_ outcome: Outcome) {
        guard !hasFinished else { return }
        hasFinished = true
        onFinish?(outcome)
    }

    private func removeWorkingDirectory() {
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    /// Small thumbnail decoded straight from the file, without loading the full image.
    static func thumbnail(of url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

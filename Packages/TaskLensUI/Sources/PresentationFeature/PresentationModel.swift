import CoreGraphics
import Foundation
import ImageIO
import Observation
import PDFKit
import TLCoreServices
import TLDomain
import TLFoundation
import TLNavigation

/// Opens a presentation through the engine and gives the screen what it needs
/// to draw the current slide.
///
/// Every slide change goes through `PresentationEngine`; this model never sets a
/// slide itself. It records nothing for Resume and never touches a document's
/// `lastReadPage`, so presenting a PDF does not move its reading position.
/// Auto play runs through `PresentationAutoPlayer`, which owns the only timer.
/// Where the presentation was left (slide and Auto Play interval) is kept per
/// presentation by `PresentationSessionRecorder` and restored on opening.
/// A PowerPoint file is presented from its rendered slide images, loaded by
/// `ImagePresentationLoader` like any image presentation.
@MainActor
@Observable
public final class PresentationModel {
    public let request: PresentationRequest
    public let engine: PresentationEngine
    public let autoPlayer: PresentationAutoPlayer
    /// The PDF being presented. PDFKit reads pages only when one is drawn.
    public private(set) var pdf: PDFDocument?
    /// Image titles seen so far, for VoiceOver.
    public private(set) var imageTitles: [DocumentID: String] = [:]
    /// Why a PowerPoint file failed to load (A9.5.1), for the failure screen.
    /// The engine's phase is unchanged: `error(.unsupportedSource)` or `error(.unreadable)`.
    public private(set) var powerPointFailure: PowerPointFailure?

    /// Saves where this presentation is left; nil keeps nothing.
    public let sessionRecorder: PresentationSessionRecorder?

    private let documentService: DocumentService
    private let sessionStore: PresentationSessionStore?
    /// Renders (or finds) the slide images of a PowerPoint file.
    private let slideImages: (any PowerPointSlideImageProviding)?
    /// Import PDF on the failure screen. Nil hides the action.
    private let onImportPDF: (@MainActor () -> Void)?

    public init(
        request: PresentationRequest,
        documentService: DocumentService,
        sessionStore: PresentationSessionStore? = nil,
        slideImages: (any PowerPointSlideImageProviding)? = nil,
        engine: PresentationEngine? = nil,
        autoPlaySleep: PresentationAutoPlayer.Sleep? = nil,
        onImportPDF: (@MainActor () -> Void)? = nil
    ) {
        self.request = request
        self.documentService = documentService
        self.sessionStore = sessionStore
        self.slideImages = slideImages
        self.onImportPDF = onImportPDF
        sessionRecorder = sessionStore.map { PresentationSessionRecorder(source: request.sessionSource, store: $0) }
        let engine = engine ?? PresentationEngine()
        self.engine = engine
        autoPlayer = autoPlaySleep.map { PresentationAutoPlayer(engine: engine, sleep: $0) }
            ?? PresentationAutoPlayer(engine: engine)
    }

    public var title: String { engine.document?.title ?? "" }
    public var phase: PresentationState.Phase { engine.phase }
    public var hasSlides: Bool { engine.state.hasSlides }
    /// One-based, for display.
    public var slideNumber: Int { engine.state.displaySlideNumber }
    public var slideCount: Int { engine.slideCount }
    public var canGoBack: Bool { hasSlides && engine.currentSlide > 0 }
    public var canGoForward: Bool { hasSlides && engine.currentSlide + 1 < engine.slideCount }
    public var currentSlide: PresentationSlide? { engine.currentSlideContent }

    /// What VoiceOver reads as the slide's content: the image's name, or the PDF's
    /// or PowerPoint file's title.
    public var currentSlideDescription: String {
        switch currentSlide?.source {
        case .image(let id): imageTitles[id] ?? ""
        case .pdfPage, .renderedImage: title
        case nil: ""
        }
    }

    public func load() async {
        guard engine.phase == .idle else { return }
        let saved = await sessionStore?.session(for: request.sessionSource)
        switch request {
        case .pdf(let id):
            await engine.load(from: PDFPresentationLoader(documentID: id, documentService: documentService))
            await restore(saved)
            if engine.state.hasSlides, let document = try? await documentService.document(id: id) {
                pdf = PDFDocument(url: documentService.fileURL(for: document))
            }
        case .images(let ids):
            await engine.load(from: ImagePresentationLoader(documentIDs: ids, documentService: documentService))
            await restore(saved)
        case .powerPoint(let id):
            if let slideImages {
                let loader = ImagePresentationLoader(powerPoint: id, slideImages: slideImages, documentService: documentService)
                await engine.load(from: PowerPointLoad(loader: loader) { [weak self] in self?.powerPointFailure = $0 })
            } else {
                await engine.load(from: NoSlideImages())
            }
            await restore(saved)
        }
    }

    // MARK: Session

    /// The state to save now.
    private var sessionSnapshot: PresentationSessionRecorder.Snapshot {
        .init(currentSlide: engine.currentSlide, slideCount: engine.slideCount, autoPlayInterval: autoPlayer.interval)
    }

    /// Opens on the saved slide and interval. Runs right after loading, before
    /// anything else suspends, so the first slide never flashes.
    ///
    /// A saved slide is used only when the slide count is unchanged and the slide
    /// is in range; otherwise the source changed, the presentation opens on the
    /// first slide, and that replaces the stale record. A presentation that no
    /// longer loads (document deleted, unreadable, empty) loses its record.
    /// Auto Play never starts on its own after restoring.
    private func restore(_ saved: PresentationSession?) async {
        guard let recorder = sessionRecorder else { return }
        guard engine.state.hasSlides else {
            if saved != nil { try? await sessionStore?.remove(request.sessionSource) }
            return
        }
        if let saved {
            if let interval = saved.autoPlayInterval { autoPlayer.setInterval(interval) }
            if let slide = saved.restorableSlide(forSlideCount: engine.slideCount) {
                if slide != engine.currentSlide { _ = engine.goToSlide(slide) }
                recorder.markStored(sessionSnapshot)
            } else {
                recorder.record(sessionSnapshot)
            }
        }
        observeSession()
    }

    /// Records the state each time the slide or interval changes, whoever changed it
    /// (buttons, Go to Slide or Auto Play).
    private func observeSession() {
        withObservationTracking {
            _ = engine.state.currentSlide
            _ = autoPlayer.interval
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recordSession()
                self.observeSession()
            }
        }
    }

    private func recordSession() {
        guard engine.state.hasSlides else { return }
        sessionRecorder?.record(sessionSnapshot)
    }

    // MARK: Failure (A9.5.2)

    /// What the failure screen shows for a PowerPoint file that didn't load;
    /// nil while loading, when presenting, for other sources, and when the
    /// load was cancelled.
    public var failureContent: PowerPointFailureContent? {
        guard case .error = engine.phase, let powerPointFailure,
              let content = PowerPointFailureContent(powerPointFailure)
        else { return nil }
        return onImportPDF == nil ? content.removing(.importPDF) : content
    }

    /// The load stopped because the person left; nothing is shown for it.
    public var wasCancelled: Bool { powerPointFailure == .cancelled }

    /// Loads the file again through the same cache, renderer and engine.
    /// Only where the failure screen offers Try Again.
    public func retry() async {
        guard failureContent?.canRetry == true else { return }
        powerPointFailure = nil
        engine.reset()
        await load()
    }

    /// Hands Import PDF to the caller. The PDF fallback itself is A9.5.3.
    public func importPDF() {
        guard failureContent?.canImportPDF == true else { return }
        onImportPDF?()
    }

    /// Records the current state and waits until it is stored.
    public func saveSession() async {
        recordSession()
        await sessionRecorder?.flush()
    }

    // MARK: Commands (all through the engine)

    public func next() {
        _ = engine.next()
        autoPlayer.slideChangedByUser()
    }

    public func previous() {
        _ = engine.previous()
        autoPlayer.slideChangedByUser()
    }

    /// `number` is one-based, as the user types it.
    public func goToSlide(number: Int) {
        _ = engine.goToSlide(number - 1)
        autoPlayer.slideChangedByUser()
    }

    // MARK: Auto play

    public enum AutoPlayButton: Equatable { case start, pause, resume }

    /// What the play button does now.
    public var autoPlayButton: AutoPlayButton {
        switch engine.phase {
        case .playing: .pause
        case .paused: .resume
        default: .start
        }
    }

    /// True while playback is running or paused, so Stop applies.
    public var isAutoPlayActive: Bool {
        switch engine.phase {
        case .playing, .paused, .completed: true
        default: false
        }
    }

    public var isAutoPlaying: Bool { autoPlayer.isPlaying }
    public var autoPlayInterval: Int { autoPlayer.interval }

    /// Play, Pause or Resume, as the button shows.
    public func toggleAutoPlay() {
        switch autoPlayButton {
        case .start: _ = autoPlayer.play()
        case .pause: _ = autoPlayer.pause()
        case .resume: _ = autoPlayer.resume()
        }
    }

    public func stopAutoPlay() { _ = autoPlayer.stop() }

    /// Seconds per slide; out-of-range values are clamped.
    public func setAutoPlayInterval(_ seconds: Int) { autoPlayer.setInterval(seconds) }

    /// iOS suspends a backgrounded app, so playback pauses and waits for Resume
    /// instead of jumping ahead when the app returns.
    public func didEnterBackground() {
        _ = autoPlayer.pause()
        recordSession()
    }

    /// Leaving the screen ends playback; nothing keeps counting after it closes.
    public func didLeave() {
        _ = autoPlayer.stop()
        recordSession()
    }

    // MARK: Rendering

    /// The image of an image slide or a rendered PowerPoint slide, decoded at no
    /// more than `maxPixelSize` on its longest side; nil for a PDF page.
    public func image(for source: PresentationSlideSource, maxPixelSize: CGFloat) async -> CGImage? {
        switch source {
        case .image(let id):
            return await image(for: id, maxPixelSize: maxPixelSize)
        case .renderedImage(let id, let index):
            guard let url = slideImages?.slideImage(for: id, index: index) else { return nil }
            return await Task.detached(priority: .userInitiated) {
                Self.downsampledImage(at: url, maxPixelSize: maxPixelSize)
            }.value
        case .pdfPage:
            return nil
        }
    }

    /// The image for an image slide, decoded at no more than `maxPixelSize` on
    /// its longest side. Only the slide on screen is decoded.
    public func image(for id: DocumentID, maxPixelSize: CGFloat) async -> CGImage? {
        guard let document = try? await documentService.document(id: id) else { return nil }
        imageTitles[id] = document.title
        let url = documentService.fileURL(for: document)
        return await Task.detached(priority: .userInitiated) {
            Self.downsampledImage(at: url, maxPixelSize: maxPixelSize)
        }.value
    }

    nonisolated static func downsampledImage(at url: URL, maxPixelSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(Int(maxPixelSize.rounded(.up)), 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

extension PresentationRequest {
    /// The saved-session identity of this presentation.
    public var sessionSource: PresentationSessionSource {
        switch self {
        case .pdf(let id): .pdf(id)
        case .images(let ids): .images(ids)
        case .powerPoint(let id): .powerPoint(id)
        }
    }
}

/// Loads a PowerPoint file and reports why it failed, as a `PowerPointFailure`.
/// The engine still gets the error it always got, so its phase is unchanged.
private struct PowerPointLoad: PresentationLoading {
    let loader: ImagePresentationLoader
    let report: @MainActor @Sendable (PowerPointFailure) -> Void

    func loadPresentation() async throws -> PresentationDocument {
        do {
            return try await loader.loadPresentation()
        } catch {
            let failure = PowerPointFailure(error)
            await report(failure)
            // Errors from the renderer and cache are mapped; the loader's own pass through unchanged.
            throw error is PowerPointFailure || error is PowerPointRenderError ? failure.presentationError : error
        }
    }
}

/// Used when no PowerPoint renderer was given: the presentation fails cleanly.
private struct NoSlideImages: PresentationLoading {
    func loadPresentation() async throws -> PresentationDocument {
        throw TaskLensError.unsupportedContent(type: "pptx")
    }
}

import Foundation
import Observation
import TLDomain
import TLFoundation

/// Produces the slides of a presentation. PDF and image sources come in A3 and A4;
/// the engine itself never opens files.
public protocol PresentationLoading: Sendable {
    func loadPresentation() async throws -> PresentationDocument
}

/// Runs one presentation: loading, slide navigation and play/pause.
///
/// The engine owns a `PresentationState` and changes it only through that
/// type's transitions. Every operation returns false, changing nothing, when it
/// does not apply in the current phase. `playing` is a phase only: the engine
/// starts no timer and never advances slides by itself (auto play is A6).
///
/// `currentSlide` is zero-based and belongs to the presentation. The engine
/// never reads or writes a document's `lastReadPage`.
@MainActor
@Observable
public final class PresentationEngine {
    public private(set) var state = PresentationState()
    public private(set) var document: PresentationDocument?

    /// Bumped on every load and reset, so a slow load that finishes late is ignored.
    @ObservationIgnored private var loadGeneration = 0

    public init() {}

    public var phase: PresentationState.Phase { state.phase }
    public var currentSlide: Int { state.currentSlide }
    public var slideCount: Int { state.slideCount }
    public var currentSlideContent: PresentationSlide? { document?.slide(at: state.currentSlide) }

    // MARK: Loading

    /// Loads slides from a source. `startAt` is a zero-based slide, clamped into range.
    /// A load replaces any presentation already loaded.
    @discardableResult
    public func load(from loader: some PresentationLoading, startAt: Int = 0) async -> Bool {
        guard state.beginLoading() else { return false }
        document = nil
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let loaded = try await loader.loadPresentation()
            guard generation == loadGeneration else { return false }
            guard loaded.sourceType.isSupported else {
                state.fail(.unsupportedSource)
                return false
            }
            document = loaded
            state.finishLoading(slideCount: loaded.slideCount, startAt: startAt)
            return state.hasSlides
        } catch {
            guard generation == loadGeneration else { return false }
            state.fail(Self.failure(for: error))
            return false
        }
    }

    /// Drops the presentation and returns to idle.
    public func reset() {
        loadGeneration += 1
        document = nil
        state = PresentationState()
    }

    // MARK: Playback

    /// Presents from the first slide.
    @discardableResult
    public func start() -> Bool {
        guard state.hasSlides else { return false }
        let moved = state.goTo(slide: 0)
        if state.phase == .playing { return moved }
        return state.start() || moved
    }

    /// Presents from the current slide. From completed, starts again at the first slide.
    @discardableResult
    public func play() -> Bool {
        state.start()
    }

    @discardableResult
    public func pause() -> Bool {
        state.pause()
    }

    /// Continues a paused presentation from the same slide.
    @discardableResult
    public func resume() -> Bool {
        guard state.phase == .paused else { return false }
        return state.start()
    }

    /// Stops presenting and goes back to ready. The current slide is kept.
    @discardableResult
    public func stop() -> Bool {
        state.stop()
    }

    // MARK: Navigation

    @discardableResult
    public func next() -> Bool {
        state.next()
    }

    @discardableResult
    public func previous() -> Bool {
        state.previous()
    }

    /// Goes to a zero-based slide. An index outside `0..<slideCount` is rejected
    /// rather than clamped, so a stale or mistyped number never moves the slide.
    @discardableResult
    public func goToSlide(_ index: Int) -> Bool {
        guard (0..<state.slideCount).contains(index) else { return false }
        return state.goTo(slide: index)
    }

    // MARK: Errors

    static func failure(for error: any Error) -> PresentationFailure {
        switch error as? TaskLensError {
        case .validationFailed(.emptyContent): .empty
        case .unsupportedContent: .unsupportedSource
        default: .unreadable
        }
    }
}

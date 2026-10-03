import Foundation

/// Why a presentation could not be shown.
public enum PresentationFailure: String, Codable, Sendable, CaseIterable {
    /// The source has no slides.
    case empty
    /// The source type cannot be presented (PowerPoint, unknown).
    case unsupportedSource
    /// The file could not be opened.
    case unreadable
}

/// Where a presentation is in its lifecycle and which slide is showing.
///
/// A pure value: each transition checks the current phase and returns false,
/// changing nothing, when it does not apply. It runs no timers and loads no
/// files; that is the engine's job (A2).
///
/// `currentSlide` is zero-based, `0 ... slideCount - 1`. The UI shows
/// `currentSlide + 1` of `slideCount`.
public struct PresentationState: Codable, Sendable, Equatable {
    public enum Phase: Codable, Sendable, Equatable {
        case idle
        case loading
        case ready
        case playing
        case paused
        case completed
        case error(PresentationFailure)
    }

    public private(set) var phase: Phase
    public private(set) var currentSlide: Int
    public private(set) var slideCount: Int

    public init() {
        phase = .idle
        currentSlide = 0
        slideCount = 0
    }

    /// One-based slide number for display, or 0 when there are no slides.
    public var displaySlideNumber: Int { slideCount > 0 ? currentSlide + 1 : 0 }
    public var isFirstSlide: Bool { currentSlide == 0 }
    public var isLastSlide: Bool { slideCount > 0 && currentSlide == slideCount - 1 }

    /// True once slides are loaded and until an error or a new load.
    public var hasSlides: Bool {
        switch phase {
        case .ready, .playing, .paused, .completed: true
        case .idle, .loading, .error: false
        }
    }

    // MARK: Loading

    @discardableResult
    public mutating func beginLoading() -> Bool {
        guard phase != .loading else { return false }
        phase = .loading
        currentSlide = 0
        slideCount = 0
        return true
    }

    /// Finishes loading. `startAt` is clamped into range; zero slides is an error.
    @discardableResult
    public mutating func finishLoading(slideCount: Int, startAt: Int = 0) -> Bool {
        guard phase == .loading else { return false }
        guard slideCount > 0 else {
            phase = .error(.empty)
            return true
        }
        self.slideCount = slideCount
        currentSlide = Self.clamp(startAt, count: slideCount)
        phase = .ready
        return true
    }

    @discardableResult
    public mutating func fail(_ failure: PresentationFailure) -> Bool {
        phase = .error(failure)
        return true
    }

    // MARK: Playback

    /// Starts from ready or paused. From completed it starts again at the first slide.
    @discardableResult
    public mutating func start() -> Bool {
        switch phase {
        case .ready, .paused:
            phase = .playing
        case .completed:
            currentSlide = 0
            phase = .playing
        default:
            return false
        }
        return true
    }

    @discardableResult
    public mutating func pause() -> Bool {
        guard phase == .playing else { return false }
        phase = .paused
        return true
    }

    /// Stops presenting and goes back to ready. The current slide is kept.
    @discardableResult
    public mutating func stop() -> Bool {
        switch phase {
        case .playing, .paused, .completed:
            phase = .ready
            return true
        default:
            return false
        }
    }

    // MARK: Navigation

    /// Moves forward one slide. On the last slide while playing, the
    /// presentation completes and the slide stays where it is.
    @discardableResult
    public mutating func next() -> Bool {
        guard hasSlides else { return false }
        if currentSlide + 1 < slideCount {
            return goTo(slide: currentSlide + 1)
        }
        guard phase == .playing else { return false }
        phase = .completed
        return true
    }

    @discardableResult
    public mutating func previous() -> Bool {
        guard hasSlides, currentSlide > 0 else { return false }
        return goTo(slide: currentSlide - 1)
    }

    /// Jumps to a zero-based slide, clamped into range. Leaving a completed
    /// presentation pauses it.
    @discardableResult
    public mutating func goTo(slide index: Int) -> Bool {
        guard hasSlides else { return false }
        let target = Self.clamp(index, count: slideCount)
        guard target != currentSlide else { return false }
        currentSlide = target
        if phase == .completed { phase = .paused }
        return true
    }

    private static func clamp(_ index: Int, count: Int) -> Int {
        min(max(index, 0), count - 1)
    }
}

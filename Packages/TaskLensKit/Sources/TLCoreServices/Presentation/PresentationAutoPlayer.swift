import Foundation
import Observation
import TLDomain

/// Advances a presentation's slides on a timer.
///
/// It drives an existing `PresentationEngine` through its public commands
/// (`play`, `pause`, `resume`, `stop`, `next`) and owns at most one countdown
/// task at a time: every command cancels the old task before starting a new
/// one, and a task that wakes after being replaced does nothing. On the last
/// slide the engine completes and the countdown ends; it never loops.
///
/// Like the engine, it never reads or writes a document's `lastReadPage`.
@MainActor
@Observable
public final class PresentationAutoPlayer {
    /// The intervals offered in the UI, in seconds.
    public nonisolated static let presetIntervals = [5, 10, 15, 30, 60]
    /// Allowed custom intervals, in seconds.
    public nonisolated static let intervalRange = 1...3600
    public nonisolated static let defaultInterval = 10

    public let engine: PresentationEngine
    /// Seconds each slide stays on screen while playing.
    public private(set) var interval: Int

    /// Waits for one interval. Tests replace it to control time.
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private var countdown: Task<Void, Never>?
    /// Bumped whenever the countdown is cancelled, so a task that is already
    /// past its sleep cannot advance a slide.
    @ObservationIgnored private var generation = 0

    public init(
        engine: PresentationEngine,
        interval: Int = PresentationAutoPlayer.defaultInterval,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.engine = engine
        self.interval = Self.clamp(interval)
        self.sleep = sleep
    }

    /// True while slides advance on their own.
    public var isPlaying: Bool { engine.phase == .playing }
    /// True while a countdown task exists. At most one ever does.
    public var hasCountdown: Bool { countdown != nil }

    // MARK: Commands

    /// Starts advancing from the current slide. From completed, starts again at
    /// the first slide. Calling it while already playing changes nothing.
    @discardableResult
    public func play() -> Bool {
        if engine.phase == .playing {
            if countdown == nil { startCountdown() }
            return false
        }
        if engine.phase == .paused { return resume() }
        guard engine.play() else { return false }
        startCountdown()
        return true
    }

    @discardableResult
    public func pause() -> Bool {
        cancelCountdown()
        return engine.pause()
    }

    /// Continues from the current slide with a full interval.
    @discardableResult
    public func resume() -> Bool {
        guard engine.resume() else { return false }
        startCountdown()
        return true
    }

    /// Ends playback and keeps the current slide.
    @discardableResult
    public func stop() -> Bool {
        cancelCountdown()
        return engine.stop()
    }

    /// Changes the interval. While playing, the new interval starts now.
    public func setInterval(_ seconds: Int) {
        let clamped = Self.clamp(seconds)
        guard clamped != interval else { return }
        interval = clamped
        if engine.phase == .playing { startCountdown() }
    }

    /// Call after the user changes the slide by hand: while playing, the new
    /// slide gets a full interval; otherwise any countdown is dropped.
    public func slideChangedByUser() {
        if engine.phase == .playing {
            startCountdown()
        } else {
            cancelCountdown()
        }
    }

    // MARK: Countdown

    private func startCountdown() {
        cancelCountdown()
        let generation = generation
        let duration = Duration.seconds(interval)
        let sleep = sleep
        countdown = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(duration) } catch { return }
                guard let self, self.advance(generation: generation) else { return }
            }
        }
    }

    /// Moves one slide. Returns false when the countdown should end.
    private func advance(generation: Int) -> Bool {
        // A replaced countdown leaves the new one alone.
        guard generation == self.generation, !Task.isCancelled else { return false }
        if engine.phase == .playing { engine.next() }
        guard engine.phase == .playing else {
            // The last slide completed the presentation, or playback ended elsewhere.
            countdown = nil
            return false
        }
        return true
    }

    private func cancelCountdown() {
        generation += 1
        countdown?.cancel()
        countdown = nil
    }

    private static func clamp(_ seconds: Int) -> Int {
        min(max(seconds, intervalRange.lowerBound), intervalRange.upperBound)
    }
}

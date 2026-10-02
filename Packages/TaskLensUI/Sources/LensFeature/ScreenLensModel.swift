import CoreGraphics
import Foundation
import Observation
import TLCoreServices
import TLDomain
import TLFoundation
import UIKit

/// Screen Lens: the user starts it, picks what to share in the system picker,
/// taps Capture, and gets "Lens found: 💰 $199" with recommended actions.
///
/// Privacy rules it keeps:
/// - It starts only from the user's tap, through the system picker; iOS shows
///   its recording indicator the whole time, and TaskLens shows its own
///   status with a Stop button (and a Live Activity where available).
/// - One frame per capture; the stream stops right after it, on Stop, or after
///   `ScreenLensSession.maximumLiveDuration`. There is no background monitoring.
/// - Frames stay in memory and are dropped once read. Nothing is written to
///   disk unless the user saves a result, and nothing leaves the device.
///
/// One instance per app run, so the Live Activity buttons and every Lens
/// screen share it.
@MainActor
@Observable
public final class ScreenLensModel {
    public private(set) var session: ScreenLensSession
    /// What the last capture found; reuses the image Lens pipeline and its
    /// "Possible match" rules.
    public let results: ImageLensModel
    public private(set) var highlights: [LensHighlight] = []

    private let capture: any ScreenCapturing
    private let status: (any ScreenLensStatusPublishing)?
    private let clock: any DateProviding
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public init(
        capture: any ScreenCapturing,
        results: ImageLensModel,
        status: (any ScreenLensStatusPublishing)? = nil,
        clock: any DateProviding = SystemDateProvider()
    ) {
        self.capture = capture
        self.results = results
        self.status = status
        self.clock = clock
        self.session = ScreenLensSession(isAvailable: capture.isAvailable)
    }

    public var state: ScreenLensSession.State { session.state }

    // MARK: User actions

    public func start() {
        apply(.start)
    }

    /// Takes a frame after `delay` seconds (0 = now).
    public func captureFrame(after delay: TimeInterval = ScreenLensSession.defaultCaptureDelay) {
        apply(.capture(delay: delay))
    }

    public func stop() {
        apply(.stop)
    }

    /// Clears the results and any frame: nothing from the capture remains.
    public func clear() {
        results.clear()
        highlights = []
        apply(.reset)
    }

    /// Checks the countdown and time limit. Called every second while live,
    /// and when the app becomes active.
    public func tick() {
        apply(.tick)
    }

    // MARK: Lifecycle

    private func apply(_ event: ScreenLensSession.Event) {
        let effects = session.handle(event, now: clock.now())
        for effect in effects {
            perform(effect)
        }
        updateTicker()
        publishStatus()
    }

    private func perform(_ effect: ScreenLensSession.Effect) {
        switch effect {
        case .presentPicker:
            results.clear()
            highlights = []
            capture.start { [weak self] event in self?.received(event) }
        case .takeFrame:
            let frame = capture.currentFrame()
            Task { await self.read(frame) }
        case .stopStream:
            Task { await capture.stop() }
        case .discardFrames:
            // The capture holds at most one frame; stopping drops it. Results
            // keep only the recognized text, never the frame.
            break
        }
    }

    private func received(_ event: ScreenCaptureEvent) {
        switch event {
        case .started: apply(.streamStarted)
        case .cancelled: apply(.pickerCancelled)
        case .failed: apply(session.state == .choosing ? .pickerFailed : .streamEnded(error: true))
        case .ended(let error): apply(.streamEnded(error: error))
        }
    }

    private func read(_ frame: CGImage?) async {
        guard let frame else {
            apply(.noFrame)
            return
        }
        apply(.frameTaken)
        await results.read(UIImage(cgImage: frame), source: .screenCapture)
        // The frame is not kept, not even for display: only the text read from it.
        results.discardPreview()
        let success = results.phase == .done
        if success, let report = results.report {
            highlights = LensHighlight.highlights(of: report, source: .screenCapture)
        }
        apply(.analysisFinished(success: success))
    }

    private func updateTicker() {
        guard session.isCapturing else {
            ticker?.cancel()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    // MARK: Status outside the app

    @ObservationIgnored private var lastPublished: ScreenLensStatus?
    @ObservationIgnored private var statusStartedAt: Date?

    private func publishStatus() {
        guard let status else { return }
        let next = statusContent()
        guard next != lastPublished else { return }
        let wasShowing = lastPublished != nil
        lastPublished = next
        Task {
            switch next?.phase {
            case .live, .countdown, .reading:
                if let next { await status.show(next) }
            case .found, .nothing:
                // The result stays on the Lock Screen briefly; capture has stopped.
                await status.end(final: next)
            case nil:
                if wasShowing { await status.end(final: nil) }
            }
        }
    }

    /// The Live Activity content for the current state; nil ends it.
    func statusContent() -> ScreenLensStatus? {
        let now = clock.now()
        switch session.state {
        case .live, .countdown, .reading:
            let since = session.liveSince ?? statusStartedAt ?? now
            statusStartedAt = since
            let endsAt = session.endsAt ?? since.addingTimeInterval(ScreenLensSession.maximumLiveDuration)
            if case .countdown(let captureAt) = session.state {
                return ScreenLensStatus(phase: .countdown, liveSince: since, endsAt: endsAt, captureAt: captureAt)
            }
            return ScreenLensStatus(phase: session.state == .reading ? .reading : .live, liveSince: since, endsAt: endsAt)
        case .done where statusStartedAt != nil:
            let since = statusStartedAt ?? now
            let lines = highlights.map(ScreenLensStatus.line(for:))
            return ScreenLensStatus(
                phase: lines.isEmpty ? .nothing : .found,
                liveSince: since,
                endsAt: since.addingTimeInterval(ScreenLensSession.maximumLiveDuration),
                highlights: lines
            )
        default:
            statusStartedAt = nil
            return nil
        }
    }
}

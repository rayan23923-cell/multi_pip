import AVFoundation
import AVKit
import CoreMedia
import UIKit

/// What the system Picture in Picture reports back.
public enum PiPEngineEvent: Sendable, Equatable {
    case possibleChanged(Bool)
    case didStart
    case failedToStart
    /// The window closed. `restored` is true when the user tapped it to
    /// return to TaskLens.
    case didStop(restored: Bool)
    /// The user tapped the window to return to TaskLens.
    case restoreRequested
    /// A skip button in the window, if iOS shows one: +1 next card, −1 previous.
    case skip(Int)
    /// The frame could not be shown (after an interruption or decode error).
    case needsFrame
}

/// Picture in Picture as TaskLens uses it. The real one is AVKit; tests use a fake.
@MainActor
public protocol PictureInPictureEngine: AnyObject {
    /// False on devices without Picture in Picture. Never true for an overlay
    /// of arbitrary views: the window shows the frames TaskLens draws.
    var isSupported: Bool { get }
    var isPossible: Bool { get }
    var isActive: Bool { get }
    var onEvent: (@MainActor (PiPEngineEvent) -> Void)? { get set }
    /// The layer that must be on screen in TaskLens for Picture in Picture to start.
    var sourceLayer: CALayer? { get }
    func display(_ frame: CMSampleBuffer)
    func start()
    func stop()
    /// Lets Picture in Picture start by itself when the user leaves TaskLens
    /// while the preview is on screen.
    func setStartsAutomatically(_ enabled: Bool)
}

/// AVKit's Picture in Picture fed with sample buffers (iOS 15+ public API).
///
/// Needs the "Audio, AirPlay, and Picture in Picture" background mode and a
/// playback audio session. Plays no sound; it mixes with other audio.
/// Lives as long as the app, like the window it drives.
@MainActor
public final class AVKitPictureInPictureEngine: NSObject, PictureInPictureEngine {
    public var onEvent: (@MainActor (PiPEngineEvent) -> Void)?
    public let isSupported: Bool
    public private(set) var isPossible = false
    public private(set) var isActive = false

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var restoring = false
    private var lastFrame: CMSampleBuffer?

    public var sourceLayer: CALayer? { displayLayer }
    private var renderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }

    public override init() {
        isSupported = AVPictureInPictureController.isPictureInPictureSupported()
        super.init()
        displayLayer.videoGravity = .resizeAspect
        guard isSupported else { return }

        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        // There is no timeline to scrub; cards change from TaskLens.
        controller.requiresLinearPlayback = true
        self.controller = controller
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor [weak self] in self?.updatePossible(possible) }
        }
        // After a lock or while in the background the decoder may stop; the
        // frame is enqueued again (with a flush when needed) on return.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(displayNeedsRecovery), name: UIApplication.willEnterForegroundNotification, object: nil)
        center.addObserver(self, selector: #selector(displayNeedsRecovery), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    public func display(_ frame: CMSampleBuffer) {
        lastFrame = frame
        enqueue(frame)
        controller?.invalidatePlaybackState()
    }

    public func start() {
        guard let controller, controller.isPictureInPicturePossible else {
            onEvent?(.failedToStart)
            return
        }
        activateAudioSession()
        controller.startPictureInPicture()
    }

    public func stop() {
        controller?.stopPictureInPicture()
    }

    public func setStartsAutomatically(_ enabled: Bool) {
        controller?.canStartPictureInPictureAutomaticallyFromInline = enabled
        if enabled { activateAudioSession() }
    }

    private func enqueue(_ frame: CMSampleBuffer) {
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
        }
        renderer.enqueue(frame)
    }

    private func updatePossible(_ possible: Bool) {
        guard isPossible != possible else { return }
        isPossible = possible
        onEvent?(.possibleChanged(possible))
    }

    /// After a lock, a call or a decode error the renderer may drop its frame.
    /// Notifications may arrive on any thread.
    @objc nonisolated private func displayNeedsRecovery() {
        Task { @MainActor [weak self] in
            guard let self, let lastFrame = self.lastFrame else { return }
            self.enqueue(lastFrame)
            self.onEvent?(.needsFrame)
        }
    }

    /// Picture in Picture requires a playback session. Mixing keeps the
    /// user's music playing; TaskLens itself plays nothing.
    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    fileprivate func handleStarted() {
        isActive = true
        onEvent?(.didStart)
    }

    fileprivate func handleFailedToStart() {
        isActive = false
        endAudio()
        onEvent?(.failedToStart)
    }

    fileprivate func handleStopped() {
        isActive = false
        let restored = restoring
        restoring = false
        endAudio()
        onEvent?(.didStop(restored: restored))
    }

    fileprivate func handleRestore() {
        restoring = true
        onEvent?(.restoreRequested)
    }

    fileprivate func handleSkip(_ direction: Int) {
        onEvent?(.skip(direction))
    }

    private func endAudio() {
        if controller?.canStartPictureInPictureAutomaticallyFromInline != true {
            deactivateAudioSession()
        }
    }
}

// AVKit calls these on the main thread; each hops to the main actor explicitly.
extension AVKitPictureInPictureEngine: AVPictureInPictureControllerDelegate {
    nonisolated public func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.handleStarted() }
    }

    nonisolated public func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        Task { @MainActor in self.handleFailedToStart() }
    }

    nonisolated public func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.handleStopped() }
    }

    nonisolated public func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in self.handleRestore() }
        completionHandler(true)
    }
}

extension AVKitPictureInPictureEngine: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated public func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        // A card is a still frame; there is nothing to play or pause.
    }

    nonisolated public func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        // Live content, as Apple documents for a stream without a timeline:
        // the card is a still frame that changes when the user picks another.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated public func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        false
    }

    nonisolated public func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    nonisolated public func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        let direction = skipInterval.seconds < 0 ? -1 : 1
        Task { @MainActor in self.handleSkip(direction) }
        completionHandler()
    }
}

/// Picture in Picture on a device that has none. Used where AVKit reports no
/// support, and by UI tests to check that case on a simulator that has it.
@MainActor
public final class UnavailablePictureInPictureEngine: PictureInPictureEngine {
    public var onEvent: (@MainActor (PiPEngineEvent) -> Void)?
    public let isSupported = false
    public let isPossible = false
    public let isActive = false
    public let sourceLayer: CALayer? = nil

    public init() {}

    public func display(_ frame: CMSampleBuffer) {}
    public func start() { onEvent?(.failedToStart) }
    public func stop() {}
    public func setStartsAutomatically(_ enabled: Bool) {}
}

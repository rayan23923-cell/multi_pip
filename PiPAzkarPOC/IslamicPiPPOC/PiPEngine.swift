import AVFoundation
import AVKit
import UIKit

/// Owns the AVSampleBufferDisplayLayer, the AVPictureInPictureController that
/// presents it, the 5-second azkar rotation and the optional generated audio.
/// Only public AVKit / AVFoundation APIs are used.
final class PiPEngine: NSObject, ObservableObject {
    static let azkar = [
        "سُبْحَانَ اللَّهِ وَبِحَمْدِهِ",
        "الْحَمْدُ لِلَّهِ",
        "اللَّهُ أَكْبَرُ",
        "لَا إِلَهَ إِلَّا اللَّهُ",
    ]

    enum ControlsMode: String, CaseIterable, Identifiable {
        /// Infinite time range: system treats content as live, so no skip buttons.
        case live = "Live (play/pause only)"
        /// Finite time range: system shows skip back/forward buttons; we map them to previous/next.
        case steppable = "Steppable (skip = prev/next)"
        var id: String { rawValue }
    }

    // MARK: Published state for the UI

    @Published private(set) var isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    @Published private(set) var isPossible = false
    @Published private(set) var isActive = false
    @Published private(set) var isPrepared = false
    @Published private(set) var isPlaying = false
    @Published private(set) var index = 0
    @Published private(set) var logLines: [String] = []
    @Published var audioEnabled = false {
        didSet { if isPrepared { updateAudio() } }
    }
    @Published var controlsMode: ControlsMode = .steppable {
        didSet { pipController?.invalidatePlaybackState(); log("controlsMode = \(controlsMode.rawValue)") }
    }
    @Published var autoStartEnabled = true {
        didSet { pipController?.canStartPictureInPictureAutomaticallyFromInline = autoStartEnabled
                 log("canStartPictureInPictureAutomaticallyFromInline = \(autoStartEnabled)") }
    }

    var currentText: String { Self.azkar[index] }

    // MARK: Internals

    let displayLayer = AVSampleBufferDisplayLayer()
    private var pipController: AVPictureInPictureController?
    private var observations: [NSKeyValueObservation] = []
    private var timebase: CMTimebase?
    private var frameTimer: Timer?
    private var rotateTimer: Timer?
    private var audioPlayer: AVAudioPlayer?
    private var framesEnqueued = 0
    private var framesWhileBackground = 0
    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                        sourceClock: CMClockGetHostTimeClock(),
                                        timebaseOut: &tb)
        if let tb {
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 0)
            displayLayer.controlTimebase = tb
            timebase = tb
        }
        log("Device \(Self.deviceModel()) · iOS \(UIDevice.current.systemVersion)")
        log("isPictureInPictureSupported = \(isSupported)")
        // Show a first frame so the inline preview is not empty.
        enqueueCurrentFrame()

        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.framesWhileBackground = 0
            self.log("didEnterBackground (PiP active: \(self.isActive))")
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.log("willEnterForeground, frames enqueued while in background: \(self.framesWhileBackground)")
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                               object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            self?.log("AVAudioSession interruption type=\(type)")
        }
    }

    // MARK: Prepare / start / stop

    /// Configures the audio session (required by AVKit for PiP), builds the PiP
    /// controller with a sample-buffer content source, enables automatic start,
    /// and starts "playback" (the 5 s text rotation).
    func prepare() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
            log("AVAudioSession .playback/.moviePlayback active")
        } catch {
            log("AVAudioSession error: \(error.localizedDescription)")
        }

        guard isSupported else {
            log("PiP not supported on this device; stopping here")
            return
        }

        if pipController == nil {
            let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer,
                                                                    playbackDelegate: self)
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            controller.canStartPictureInPictureAutomaticallyFromInline = autoStartEnabled
            controller.requiresLinearPlayback = false
            observations = [
                controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
                    DispatchQueue.main.async {
                        self?.isPossible = c.isPictureInPicturePossible
                        self?.log("isPictureInPicturePossible = \(c.isPictureInPicturePossible)")
                    }
                },
                controller.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] c, _ in
                    DispatchQueue.main.async { self?.isActive = c.isPictureInPictureActive }
                },
            ]
            pipController = controller
            log("AVPictureInPictureController created (ContentSource: AVSampleBufferDisplayLayer)")
            log("canStartPictureInPictureAutomaticallyFromInline = \(autoStartEnabled)")
        }

        isPrepared = true
        setPlaying(true)
        startFramePump()
    }

    func startPiP() {
        guard let pipController else { log("Start PiP: prepare first"); return }
        log("startPictureInPicture() called, possible=\(pipController.isPictureInPicturePossible)")
        pipController.startPictureInPicture()
    }

    func stopPiP() {
        pipController?.stopPictureInPicture()
    }

    func next() { index = (index + 1) % Self.azkar.count; enqueueCurrentFrame() }
    func previous() { index = (index - 1 + Self.azkar.count) % Self.azkar.count; enqueueCurrentFrame() }

    // MARK: Playback state

    private func setPlaying(_ playing: Bool) {
        isPlaying = playing
        if let timebase { CMTimebaseSetRate(timebase, rate: playing ? 1 : 0) }
        rotateTimer?.invalidate()
        rotateTimer = nil
        if playing {
            let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.next() }
            RunLoop.main.add(t, forMode: .common)
            rotateTimer = t
        }
        updateAudio()
        pipController?.invalidatePlaybackState()
        log(playing ? "playing (text rotates every 5 s)" : "paused")
    }

    /// Re-enqueues the current frame twice a second so the PiP window always has
    /// a fresh frame and the footer clock proves the app is still producing content.
    private func startFramePump() {
        guard frameTimer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.enqueueCurrentFrame() }
        RunLoop.main.add(t, forMode: .common)
        frameTimer = t
    }

    private func enqueueCurrentFrame() {
        let footer = "\(index + 1)/\(Self.azkar.count) · \(clock.string(from: Date()))"
            + (isPlaying ? "" : " · paused")
        guard let pb = AzkarFrameRenderer.makePixelBuffer(text: currentText, footer: footer) else {
            log("render failed"); return
        }
        let pts = timebase.map { CMTimebaseGetTime($0) } ?? CMClockGetTime(CMClockGetHostTimeClock())
        guard let sb = AzkarFrameRenderer.makeSampleBuffer(pixelBuffer: pb, presentationTime: pts) else {
            log("sample buffer failed"); return
        }
        if #available(iOS 17.0, *) {
            let renderer = displayLayer.sampleBufferRenderer
            if renderer.status == .failed {
                log("renderer failed: \(renderer.error?.localizedDescription ?? "?"); flushing")
                renderer.flush()
            }
            renderer.enqueue(sb)
        } else {
            if displayLayer.status == .failed {
                log("layer failed: \(displayLayer.error?.localizedDescription ?? "?"); flushing")
                displayLayer.flush()
            }
            displayLayer.enqueue(sb)
        }
        framesEnqueued += 1
        if UIApplication.shared.applicationState == .background { framesWhileBackground += 1 }
    }

    // MARK: Optional audio (locally generated tone, no copyrighted content)

    private func updateAudio() {
        guard audioEnabled, isPlaying else {
            if audioPlayer?.isPlaying == true { audioPlayer?.pause(); log("audio paused") }
            return
        }
        if audioPlayer == nil {
            do {
                let url = try Self.generateChimeFile()
                let player = try AVAudioPlayer(contentsOf: url)
                player.numberOfLoops = -1
                player.volume = 0.6
                player.prepareToPlay()
                audioPlayer = player
            } catch {
                log("audio setup error: \(error.localizedDescription)")
                return
            }
        }
        audioPlayer?.play()
        log("audio playing (generated chime, loops every 5 s)")
    }

    /// Writes a 5-second WAV: a soft two-note chime followed by silence.
    private static func generateChimeFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chime.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(sampleRate * 5)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            var s = 0.0
            if t < 1.2 { s += sin(2 * .pi * 659.25 * t) * exp(-3 * t) }
            if t > 0.4 && t < 2.0 { s += sin(2 * .pi * 880.0 * (t - 0.4)) * exp(-3 * (t - 0.4)) }
            data[i] = Float(s * 0.25)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    // MARK: Logging

    func log(_ message: String) {
        let line = "\(clock.string(from: Date()))  \(message)"
        print(line)
        let append = { [weak self] in
            guard let self else { return }
            self.logLines.append(line)
            if self.logLines.count > 200 { self.logLines.removeFirst(self.logLines.count - 200) }
        }
        if Thread.isMainThread { append() } else { DispatchQueue.main.async(execute: append) }
    }

    var fullReportText: String {
        """
        Device: \(Self.deviceModel())
        iOS: \(UIDevice.current.systemVersion)
        PiP supported: \(isSupported)
        PiP possible: \(isPossible)
        PiP active: \(isActive)
        Auto-start flag: \(autoStartEnabled)
        Audio enabled: \(audioEnabled)
        Controls mode: \(controlsMode.rawValue)
        Frames enqueued: \(framesEnqueued)
        --- log ---
        \(logLines.joined(separator: "\n"))
        """
    }

    static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PiPEngine: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        let state = UIApplication.shared.applicationState
        log("PiP willStart (appState=\(state == .active ? "active" : state == .background ? "background" : "inactive"))")
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        log("PiP didStart")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        log("PiP FAILED to start: \(error.localizedDescription) [\((error as NSError).domain) \((error as NSError).code)]")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        log("PiP didStop")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        log("PiP restore UI requested (user tapped return-to-app)")
        completionHandler(true)
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PiPEngine: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        log("PiP control: setPlaying(\(playing))")
        DispatchQueue.main.async { self.setPlaying(playing) }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        switch controlsMode {
        case .live:
            // Apple: return an infinite range for live content.
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        case .steppable:
            return CMTimeRange(start: .zero, duration: CMTime(seconds: 24 * 3600, preferredTimescale: 600))
        }
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        !isPlaying
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        log("PiP render size \(newRenderSize.width)x\(newRenderSize.height)")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        let seconds = CMTimeGetSeconds(skipInterval)
        log("PiP control: skipByInterval(\(seconds)) -> \(seconds >= 0 ? "next" : "previous")")
        DispatchQueue.main.async {
            if seconds >= 0 { self.next() } else { self.previous() }
            completionHandler()
        }
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ controller: AVPictureInPictureController) -> Bool {
        false
    }
}

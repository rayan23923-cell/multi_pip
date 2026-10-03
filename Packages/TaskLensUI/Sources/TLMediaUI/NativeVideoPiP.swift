import AVFoundation
import AVKit
import CoreText
import Observation
import UIKit

/// The documented native path: AVPlayer → AVPlayerLayer →
/// AVPictureInPictureController. Proves TaskLens' Picture in Picture works
/// with media TaskLens is allowed to play (a video made on the device, or
/// Apple's public HLS example). Used by the Video PiP Lab.
@MainActor
@Observable
public final class NativeVideoPiP: NSObject {
    public enum Source: String, CaseIterable, Identifiable, Sendable {
        /// A short video TaskLens writes on the device. Works offline.
        case generated
        /// Apple's HLS example stream from developer.apple.com.
        case appleSample

        public var id: String { rawValue }
    }

    public private(set) var isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    public private(set) var isPossible = false
    public private(set) var isActive = false
    public private(set) var isPlaying = false
    public private(set) var isLoaded = false
    public private(set) var currentTime: Double = 0
    public private(set) var log: [String] = []
    public private(set) var restoreCount = 0

    @ObservationIgnored public let player = AVPlayer()
    @ObservationIgnored public let playerLayer = AVPlayerLayer()
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var timeObserver: Any?

    public static let appleSampleURL = URL(
        string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8"
    )!

    public override init() {
        super.init()
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        record("isPictureInPictureSupported = \(isSupported)")
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor [weak self] in self?.isPlaying = playing }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) {
            [weak self] time in
            MainActor.assumeIsolated { self?.currentTime = time.seconds }
        }
    }

    public func load(_ source: Source) async {
        record("load \(source.rawValue)")
        let url: URL
        switch source {
        case .generated:
            do {
                url = try await TestVideoMaker.makeIfNeeded()
            } catch {
                record("could not make the test video: \(error.localizedDescription)")
                return
            }
        case .appleSample:
            url = Self.appleSampleURL
        }
        activateAudioSession()
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        isLoaded = true
        makeController()
    }

    public func play() {
        record("play")
        player.play()
    }

    public func pause() {
        record("pause")
        player.pause()
    }

    public func seek(by seconds: Double) {
        let target = max(0, currentTime + seconds)
        record("seek to \(String(format: "%.1f", target))")
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    public func startPictureInPicture() {
        guard let controller else {
            record("startPictureInPicture: no controller (supported = \(isSupported))")
            return
        }
        record("startPictureInPicture (possible = \(controller.isPictureInPicturePossible))")
        controller.startPictureInPicture()
    }

    public func stopPictureInPicture() {
        record("stopPictureInPicture")
        controller?.stopPictureInPicture()
    }

    private func makeController() {
        guard isSupported, controller == nil else { return }
        let controller = AVPictureInPictureController(contentSource: .init(playerLayer: playerLayer))
        controller.delegate = self
        // Leaving TaskLens while this video plays starts Picture in Picture.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.controller = controller
        observations.append(controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor [weak self] in
                guard let self, self.isPossible != possible else { return }
                self.isPossible = possible
                self.record("isPictureInPicturePossible = \(possible)")
            }
        })
        observations.append(controller.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] controller, _ in
            let active = controller.isPictureInPictureActive
            Task { @MainActor [weak self] in
                guard let self, self.isActive != active else { return }
                self.isActive = active
                self.record("isPictureInPictureActive = \(active)")
            }
        })
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            record("audio session: \(error.localizedDescription)")
        }
    }

    func record(_ text: String) {
        let stamp = Date().formatted(.dateTime.hour().minute().second())
        log.append("\(stamp) \(text)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    fileprivate func delegateEvent(_ name: String) {
        record("delegate: \(name)")
        if name == "restoreUserInterface" { restoreCount += 1 }
    }
}

// AVKit calls these on the main thread.
extension NativeVideoPiP: AVPictureInPictureControllerDelegate {
    nonisolated public func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.delegateEvent("willStart") }
    }

    nonisolated public func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.delegateEvent("didStart") }
    }

    nonisolated public func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        let message = error.localizedDescription
        Task { @MainActor in self.delegateEvent("failedToStart: \(message)") }
    }

    nonisolated public func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.delegateEvent("willStop") }
    }

    nonisolated public func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.delegateEvent("didStop") }
    }

    nonisolated public func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // The lab screen is still in place under the window; nothing to rebuild.
        Task { @MainActor in self.delegateEvent("restoreUserInterface") }
        completionHandler(true)
    }
}

/// Writes a 20-second H.264 test video on the device: a counter and a moving
/// bar, so playback, pause and seek are visible. No network, no bundled media.
enum TestVideoMaker {
    static let size = CGSize(width: 640, height: 360)
    static let framesPerSecond: Int32 = 30
    static let seconds = 20

    static var url: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TaskLensPiPTest.mp4")
    }

    static func makeIfNeeded() async throws -> URL {
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let output = url
        try await Task.detached(priority: .userInitiated) { try write(to: output) }.value
        return output
    }

    private static func write(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let total = Int(framesPerSecond) * seconds
        for frame in 0..<total {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            draw(frame: frame, total: total, into: buffer)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: framesPerSecond))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private static func draw(frame: Int, total: Int, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        // Background color cycles every 10 seconds, so a frozen frame is obvious.
        let phase = CGFloat(frame % 300) / 300
        context.setFillColor(CGColor(red: 0.15 + 0.3 * phase, green: 0.2, blue: 0.45 - 0.3 * phase, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        // Progress bar along the bottom edge (CoreGraphics' origin is bottom-left).
        let progress = CGFloat(frame) / CGFloat(total)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width * progress, height: 18))

        let seconds = Double(frame) / Double(framesPerSecond)
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 40, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: String(format: "PiP test %05.2f s", seconds), attributes: attributes)
        )
        context.textPosition = CGPoint(x: 40, y: size.height / 2 - 14)
        CTLineDraw(line, context)
    }
}

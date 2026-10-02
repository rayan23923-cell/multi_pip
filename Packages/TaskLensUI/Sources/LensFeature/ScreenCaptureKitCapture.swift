#if canImport(ScreenCaptureKit) && !targetEnvironment(macCatalyst)
import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Screen capture with ScreenCaptureKit (iOS 27 and later).
///
/// The system content-sharing picker is the only way in: the user chooses
/// what to share, and iOS shows its recording indicator for as long as the
/// stream runs. No microphone or audio is captured. Frames are not recorded
/// or written anywhere: each new frame replaces the last one in memory, and
/// Screen Lens takes one of them and stops the stream.
@available(iOS 27.0, *)
@MainActor
final class ScreenCaptureKitCapture: ScreenCapturing {
    private let receiver = Receiver()
    private var stream: SCStream?
    private var onEvent: (@MainActor (ScreenCaptureEvent) -> Void)?

    init() {
        receiver.onFilter = { [weak self] filter in
            Task { @MainActor in await self?.startStream(with: filter) }
        }
        receiver.onPickerEvent = { [weak self] event in
            Task { @MainActor in self?.finish(event) }
        }
        receiver.onStreamStopped = { [weak self] in
            Task { @MainActor in
                self?.stream = nil
                self?.finish(.ended(error: true))
            }
        }
    }

    var isAvailable: Bool { SCContentSharingPicker.shared.isAvailable }

    func start(onEvent: @escaping @MainActor (ScreenCaptureEvent) -> Void) {
        self.onEvent = onEvent
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = false
        picker.defaultConfiguration = configuration
        picker.add(receiver)
        picker.isActive = true
        picker.present()
    }

    func currentFrame() -> CGImage? {
        receiver.takeFrame()
    }

    func stop() async {
        let stream = self.stream
        self.stream = nil
        onEvent = nil
        receiver.dropFrame()
        deactivatePicker()
        try? await stream?.stopCapture()
    }

    private func startStream(with filter: SCContentFilter) async {
        // A new choice replaces any earlier stream.
        if let stream { try? await stream.stopCapture() }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
        do {
            try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
            try await stream.startCapture()
            self.stream = stream
            onEvent?(.started)
        } catch {
            finish(.failed)
        }
    }

    private func finish(_ event: ScreenCaptureEvent) {
        let handler = onEvent
        if event != .started {
            onEvent = nil
            receiver.dropFrame()
            deactivatePicker()
        }
        handler?(event)
    }

    private func deactivatePicker() {
        let picker = SCContentSharingPicker.shared
        picker.remove(receiver)
        picker.isActive = false
    }

    /// Receives picker and stream callbacks on ScreenCaptureKit's queues and
    /// keeps only the newest complete frame.
    final class Receiver: NSObject, SCContentSharingPickerObserver, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
        let queue = DispatchQueue(label: "TaskLens.ScreenLens.frames")
        private let lock = NSLock()
        private var latest: CVPixelBuffer?
        private let context = CIContext()

        var onFilter: (@Sendable (SCContentFilter) -> Void)?
        var onPickerEvent: (@Sendable (ScreenCaptureEvent) -> Void)?
        var onStreamStopped: (@Sendable () -> Void)?

        func takeFrame() -> CGImage? {
            lock.lock()
            let buffer = latest
            latest = nil
            lock.unlock()
            guard let buffer else { return nil }
            let image = CIImage(cvPixelBuffer: buffer)
            return context.createCGImage(image, from: image.extent)
        }

        func dropFrame() {
            lock.lock()
            latest = nil
            lock.unlock()
        }

        // MARK: SCContentSharingPickerObserver

        func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
            onFilter?(filter)
        }

        func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
            onPickerEvent?(.cancelled)
        }

        func contentSharingPickerStartDidFailWithError(_ error: any Error) {
            onPickerEvent?(.failed)
        }

        // MARK: SCStreamDelegate

        func stream(_ stream: SCStream, didStopWithError error: any Error) {
            dropFrame()
            onStreamStopped?()
        }

        // MARK: SCStreamOutput

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, sampleBuffer.isValid, Self.isComplete(sampleBuffer),
                  let buffer = sampleBuffer.imageBuffer else { return }
            lock.lock()
            latest = buffer
            lock.unlock()
        }

        /// Only frames with new content: idle and blank frames carry no image.
        static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
                let raw = attachments.first?[.status] as? Int,
                let status = SCFrameStatus(rawValue: raw) else { return false }
            return status == .complete
        }
    }
}
#endif

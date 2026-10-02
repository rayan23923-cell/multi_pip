import LensFeature
import LiveActivitiesFeature
import UIKit

/// Builds the app's one Screen Lens.
@MainActor
enum ScreenLensSetup {
    /// UI tests on simulators without ScreenCaptureKit use a stand-in capture.
    static let fakeCaptureArgument = "-TaskLensScreenLensFake"

    static func make(container: AppContainer, arguments: [String] = ProcessInfo.processInfo.arguments) -> ScreenLensModel {
        var capture = ScreenCaptureFactory.make()
        #if DEBUG
        if arguments.contains(fakeCaptureArgument) {
            capture = UITestScreenCapture()
        }
        #endif
        let model = ScreenLensModel(
            capture: capture,
            results: ImageLensModel(
                recognizer: VisionImageRecognizer(),
                captureService: container.capture,
                sessionService: container.sessions
            ),
            status: ActivityKitScreenLensStatus()
        )
        IntentDependencies.screenLens = model
        return model
    }
}

#if DEBUG
/// For UI tests only (`-TaskLensScreenLensFake`): "picks" at once and returns a
/// drawn frame with a price and a phone number, so the whole flow after the
/// system picker runs on the simulator. Never used in release builds.
@MainActor
final class UITestScreenCapture: ScreenCapturing {
    private var running = false

    var isAvailable: Bool { true }

    func start(onEvent: @escaping @MainActor (ScreenCaptureEvent) -> Void) {
        running = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            onEvent(.started)
        }
    }

    func currentFrame() -> CGImage? {
        guard running else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 640, height: 320)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 44), .foregroundColor: UIColor.black]
            ("Price $199" as NSString).draw(at: CGPoint(x: 40, y: 60), withAttributes: attributes)
            ("Call 0771 234 5678" as NSString).draw(at: CGPoint(x: 40, y: 180), withAttributes: attributes)
        }.cgImage
    }

    func stop() async {
        running = false
    }
}
#endif

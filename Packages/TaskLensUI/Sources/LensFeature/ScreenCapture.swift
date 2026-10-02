import CoreGraphics
import Foundation

/// What the screen capture gives back to Screen Lens.
public enum ScreenCaptureEvent: Sendable, Equatable {
    /// The user picked what to share and the stream runs (the system
    /// recording indicator is now visible).
    case started
    /// The user closed the system picker without choosing.
    case cancelled
    /// The picker or stream could not start.
    case failed
    /// The stream ended without the app asking: from the system indicator,
    /// Control Center, a lock, or an error.
    case ended(error: Bool)
}

/// Screen capture through the system content-sharing picker. ScreenCaptureKit
/// on iOS 27 and later; `UnavailableScreenCapture` elsewhere; a fake in tests.
@MainActor
public protocol ScreenCapturing: AnyObject {
    /// False before iOS 27, or when screen recording is restricted on this device.
    var isAvailable: Bool { get }
    /// Shows the system picker. Nothing is captured until the user picks.
    func start(onEvent: @escaping @MainActor (ScreenCaptureEvent) -> Void)
    /// The newest frame, if one arrived. Only that one frame is held, in memory.
    func currentFrame() -> CGImage?
    /// Stops the stream and drops the held frame.
    func stop() async
}

/// Devices where screen capture isn't available (before iOS 27). Screen Lens
/// then offers the screenshot route: take a screenshot and pick it in Lens.
@MainActor
public final class UnavailableScreenCapture: ScreenCapturing {
    public init() {}
    public var isAvailable: Bool { false }
    public func start(onEvent: @escaping @MainActor (ScreenCaptureEvent) -> Void) { onEvent(.failed) }
    public func currentFrame() -> CGImage? { nil }
    public func stop() async {}
}

/// The capture this OS supports.
@MainActor
public enum ScreenCaptureFactory {
    public static func make() -> any ScreenCapturing {
        #if canImport(ScreenCaptureKit) && !targetEnvironment(macCatalyst)
        if #available(iOS 27.0, *) {
            return ScreenCaptureKitCapture()
        }
        #endif
        return UnavailableScreenCapture()
    }
}

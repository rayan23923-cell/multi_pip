import AppIntents
#if TASKLENS_APP
import LiveActivitiesFeature
import TLCoreServices
#endif

/// Capture in the Screen Lens Live Activity. Runs in the app's process without
/// bringing TaskLens forward, so the screen the user is on is what gets read.
/// The frame is taken after a short countdown, once the Lock Screen or the
/// Dynamic Island is out of the way.
struct CaptureScreenIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "intent.captureScreen.title"
    static let description: IntentDescription? = IntentDescription("intent.captureScreen.description")
    /// Only for the Live Activity button: capture is never started by Siri.
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if TASKLENS_APP
        IntentDependencies.screenLens?.captureFrame(after: ScreenLensSession.defaultCaptureDelay)
        #endif
        return .result()
    }
}

/// Stop in the Screen Lens Live Activity: ends the capture and drops any frame.
struct StopScreenLensIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "intent.stopScreenLens.title"
    static let description: IntentDescription? = IntentDescription("intent.stopScreenLens.description")
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if TASKLENS_APP
        if let screenLens = IntentDependencies.screenLens {
            screenLens.stop()
        } else {
            // Nothing is capturing in this process: just remove the activity.
            await ActivityKitScreenLensStatus.endLeftovers()
        }
        #endif
        return .result()
    }
}

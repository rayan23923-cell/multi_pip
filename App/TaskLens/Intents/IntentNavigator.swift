import Foundation
import LensFeature
import Observation

/// Hands a screen to open from App Intents (Siri, Shortcuts, widget buttons)
/// to the running UI. Intents run before or beside the UI, so they leave a
/// `tasklens://` link here and `RootView` opens it.
@MainActor
@Observable
final class IntentNavigator {
    static let shared = IntentNavigator()

    private(set) var pendingURL: URL?

    func open(_ url: URL) {
        pendingURL = url
    }

    /// The link to open, once.
    func take() -> URL? {
        defer { pendingURL = nil }
        return pendingURL
    }
}

/// What App Intents run against. The app's own container by default, so an
/// intent and the open app share one store; tests swap in a preview container.
@MainActor
enum IntentDependencies {
    static var container: AppContainer = .shared
    static var navigator: IntentNavigator = .shared
    /// Screen Lens of this app run; nil when the process was started only for an intent.
    static var screenLens: ScreenLensModel?
}

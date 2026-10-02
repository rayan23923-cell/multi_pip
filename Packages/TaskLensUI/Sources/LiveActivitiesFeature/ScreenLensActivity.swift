import ActivityKit
import Foundation
import TLCoreServices
import WidgetsFeature

/// The Screen Lens Live Activity, through ActivityKit. While Screen Lens is
/// capturing it shows the status with Capture and Stop; after a capture it
/// shows what was found for a short while. Where Live Activities are off or
/// unavailable, every call does nothing and Screen Lens works in the app.
@MainActor
public final class ActivityKitScreenLensStatus: ScreenLensStatusPublishing {
    /// How long a result stays on the Lock Screen after capture stopped.
    nonisolated public static let resultLifetime: TimeInterval = 10 * 60

    public init() {}

    public func show(_ status: ScreenLensStatus) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if !(await Self.update(status)) {
            _ = try? Activity.request(
                attributes: ScreenLensActivityAttributes(),
                content: ActivityContent(state: status, staleDate: status.endsAt),
                pushType: nil
            )
        }
    }

    public func end(final status: ScreenLensStatus?) async {
        await Self.end(final: status)
    }

    /// Ends activities left by an earlier run (the app was closed while Screen
    /// Lens ran: the stream ended with the process).
    public static func endLeftovers() async {
        await end(final: nil)
    }

    // Activities are not Sendable: they are found and changed off the main actor.

    @concurrent private nonisolated static func update(_ status: ScreenLensStatus) async -> Bool {
        let content = ActivityContent(state: status, staleDate: status.endsAt)
        var updated = false
        for activity in Activity<ScreenLensActivityAttributes>.activities
        where activity.activityState == .active || activity.activityState == .stale {
            await activity.update(content)
            updated = true
        }
        return updated
    }

    @concurrent private nonisolated static func end(final status: ScreenLensStatus?) async {
        for activity in Activity<ScreenLensActivityAttributes>.activities {
            if let status {
                await activity.end(
                    ActivityContent(state: status, staleDate: nil),
                    dismissalPolicy: .after(Date().addingTimeInterval(resultLifetime))
                )
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}

import ActivityKit
import Foundation
import Observation
import TLCoreServices
import TLData
import TLDomain
import TLFoundation
import WidgetsFeature

/// What the controller needs from ActivityKit. A fake stands in for it in tests.
@MainActor
public protocol LiveActivityClient: AnyObject {
    /// False when the user turned Live Activities off for TaskLens, or the device has none.
    var areActivitiesEnabled: Bool { get }
    /// The activities iOS is showing for TaskLens, by session. Includes ones left
    /// from an earlier run of the app.
    func running() -> [SessionID: SessionActivityContent]
    func start(_ request: SessionActivityRequest) throws
    func update(_ request: SessionActivityRequest) async
    func end(_ sessionID: SessionID) async
}

/// Keeps one Live Activity per active session (up to a few) in step with the
/// store: started when a session starts, updated as it collects items or a
/// focus timer runs, ended when it pauses, ends or is deleted.
///
/// Live Activities are optional. On a device without them, or when the user
/// turned them off, every call is a no-op and the app works as before. iPhones
/// without the Dynamic Island show the same activity on the Lock Screen.
@MainActor
@Observable
public final class LiveActivityController {
    public private(set) var lastError: String?

    private let service: SessionActivityService
    private let client: any LiveActivityClient
    private let logger: TLLogger
    private var processing: [SessionID: SessionProcessing] = [:]

    public init(service: SessionActivityService, client: any LiveActivityClient, logger: TLLogger = TLLogger(category: "liveActivity")) {
        self.service = service
        self.client = client
        self.logger = logger
    }

    public var isAvailable: Bool { client.areActivitiesEnabled }

    /// Brings the running activities in line with the store.
    public func refresh() async {
        guard client.areActivitiesEnabled else { return }
        let wanted: [SessionActivityRequest]
        do {
            wanted = try await service.wanted(processing: processing)
        } catch {
            logger.error("Live Activity refresh failed: \(error)")
            lastError = String(describing: error)
            return
        }
        for change in SessionActivityPlanner.changes(wanted: wanted, running: client.running()) {
            switch change {
            case .start(let request):
                do {
                    try client.start(request)
                } catch {
                    // iOS refuses to start activities while the app is in the
                    // background; the next refresh in the foreground retries.
                    logger.error("Live Activity start failed: \(error)")
                    lastError = String(describing: error)
                }
            case .update(let request):
                await client.update(request)
            case .end(let sessionID):
                await client.end(sessionID)
            }
        }
    }

    /// Shows work in progress for a session (for example, reading a document).
    /// Nil clears it.
    public func setProcessing(_ work: SessionProcessing?, for sessionID: SessionID) async {
        processing[sessionID] = work
        await refresh()
    }

    /// Refreshes after every change to the store until the task is cancelled.
    public func follow(_ signal: StoreChangeSignal, afterRefresh: @MainActor () async -> Void = {}) async {
        for await _ in signal.changes {
            await refresh()
            await afterRefresh()
        }
    }
}

/// ActivityKit itself.
@MainActor
public final class ActivityKitLiveActivityClient: LiveActivityClient {
    public init() {}

    public var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    private var activities: [Activity<SessionActivityAttributes>] {
        Activity<SessionActivityAttributes>.activities.filter { activity in
            activity.activityState == .active || activity.activityState == .stale
        }
    }

    public func running() -> [SessionID: SessionActivityContent] {
        var result: [SessionID: SessionActivityContent] = [:]
        for activity in activities where result[activity.attributes.sessionID] == nil {
            result[activity.attributes.sessionID] = activity.content.state
        }
        return result
    }

    public func start(_ request: SessionActivityRequest) throws {
        let attributes = SessionActivityAttributes(
            sessionID: request.sessionID, kind: request.kind, workspaceName: request.workspaceName
        )
        _ = try Activity.request(
            attributes: attributes,
            content: ActivityContent(state: request.content, staleDate: request.staleDate),
            pushType: nil
        )
    }

    public func update(_ request: SessionActivityRequest) async {
        await Self.update(request)
    }

    public func end(_ sessionID: SessionID) async {
        await Self.end(sessionID)
    }

    // Activities are not Sendable: they are found and changed off the main actor.

    @concurrent private nonisolated static func update(_ request: SessionActivityRequest) async {
        let content = ActivityContent(state: request.content, staleDate: request.staleDate)
        for activity in Activity<SessionActivityAttributes>.activities
        where activity.attributes.sessionID == request.sessionID && activity.activityState != .ended && activity.activityState != .dismissed {
            await activity.update(content)
        }
    }

    @concurrent private nonisolated static func end(_ sessionID: SessionID) async {
        for activity in Activity<SessionActivityAttributes>.activities where activity.attributes.sessionID == sessionID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

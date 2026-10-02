import AppIntents
import TLDomain
#if TASKLENS_APP
import LiveActivitiesFeature
#endif

/// The Stop button of a session's Live Activity. A Live Activity intent runs
/// in the app's process without bringing TaskLens to the front: it ends the
/// session, which ends its activity.
struct StopSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "intent.stopSession.title"
    static let description: IntentDescription? = IntentDescription("intent.stopSession.description")
    /// Only for the Live Activity button.
    static let isDiscoverable = false

    @Parameter(title: "intent.param.sessionID")
    var sessionID: String

    init() {}

    init(sessionID: SessionID) {
        self.sessionID = sessionID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if TASKLENS_APP
        guard let id = SessionID(uuidString: sessionID) else { return .result() }
        let container = IntentDependencies.container
        if let session = try? await container.sessions.session(id: id), !session.isEnded {
            _ = try await container.sessions.end(id)
        }
        // End it directly too: the app may have been launched just for this intent.
        await ActivityKitLiveActivityClient().end(id)
        await container.refreshWidgets()
        #endif
        return .result()
    }
}

import AppIntents
import Foundation
import Testing
import TLCoreServices
import TLDomain
import TLFoundation
import TLLocalization
import TLNavigation
@testable import TaskLens

/// Runs the App Intents the way Siri and Shortcuts do (`perform()`), against
/// an in-memory container instead of the app's store.
@MainActor
@Suite("App Intents", .serialized)
struct IntentTests {
    let container = AppContainer.preview()
    let navigator = IntentNavigator()

    init() {
        IntentDependencies.container = container
        IntentDependencies.navigator = navigator
    }

    @Test func appShortcutsStayWithinTheSystemLimit() {
        #expect(TaskLensShortcuts.appShortcuts.count <= TaskLensShortcuts.maximumShortcuts)
        #expect(TaskLensShortcuts.appShortcuts.count == 10)
    }

    @Test func startWorkspaceOpensIt() async throws {
        _ = try await StartWorkspaceIntent(kind: .research).perform()
        let workspaces = try await container.workspaces.list()
        #expect(workspaces.count == 1)
        let workspace = try #require(workspaces.first)
        #expect(workspace.kind == .research)
        #expect(navigator.take() == DeepLink.workspace(workspace.id))

        _ = try await StartWorkspaceIntent(kind: .research).perform()
        #expect(try await container.workspaces.list().count == 1)
    }

    @Test func openAndStartSessionNavigate() async throws {
        let workspace = try await container.workspaces.create(name: "Trip")
        _ = try await OpenWorkspaceIntent(target: WorkspaceEntity(workspace)).perform()
        #expect(navigator.take() == DeepLink.workspace(workspace.id))

        var intent = StartSessionIntent()
        intent.workspace = WorkspaceEntity(workspace)
        intent.kind = .shopping
        _ = try await intent.perform()
        let session = try #require(try await container.sessions.activeSession(in: workspace.id))
        #expect(session.kind == .shopping)
        #expect(navigator.take() == DeepLink.session(session.id))

        _ = try await OpenSessionIntent(target: SessionEntity(session, workspaceName: workspace.name)).perform()
        #expect(navigator.take() == DeepLink.resume(session.id))
    }

    @Test func saveToShoppingSession() async throws {
        _ = try await SaveToSessionIntent(text: "https://apple.com/shop", sessionKind: .shopping).perform()
        let session = try #require(try await container.systemActions.session(ofKind: .shopping))
        let items = try await container.capture.items(in: session.id)
        #expect(items.count == 1)
        #expect(items.first?.source == .appIntent)
        // Saving runs in the background: no screen is opened.
        #expect(navigator.pendingURL == nil)
    }

    @Test func saveWithoutSessionGoesToTheInbox() async throws {
        _ = try await SaveContentIntent(text: "Remember the milk").perform()
        #expect(SaveContentIntent.message(for: .inbox) == L10n.string(.intentResultSavedToInbox))
    }

    @Test func sendToTaskLensOpensLensWithTheText() async throws {
        _ = try await SendToTaskLensIntent(text: "Call +1 555 0100 & email a@b.co").perform()
        let url = try #require(navigator.take())
        #expect(DeepLink.route(for: url)?.route == .lensInput("Call +1 555 0100 & email a@b.co"))

        await #expect(throws: TaskLensError.self) {
            _ = try await SendToTaskLensIntent(text: "  ").perform()
        }
    }

    @Test func toolIntentsOpenTheirScreens() async throws {
        _ = try await StartLensIntent().perform()
        #expect(navigator.take() == DeepLink.lens)
        _ = try await OpenClipboardIntent().perform()
        #expect(navigator.take() == DeepLink.clipboard)
        for destination in QuickDestination.allCases {
            _ = try await OpenDestinationIntent(destination.destination).perform()
            #expect(navigator.take() == destination.destination.url)
        }
    }

    @Test func createNoteSavesIt() async throws {
        _ = try await CreateNoteIntent(text: "Trip\nBook the hotel").perform()
        let notes = try await container.notes.allNotes()
        #expect(notes.map(\.title) == ["Trip"])
    }

    @Test func calculateAndConvert() async throws {
        _ = try await CalculateIntent(expression: "12×3+4").perform()
        await #expect(throws: TaskLensError.self) {
            _ = try await CalculateIntent(expression: "hello").perform()
        }

        _ = try await ConvertCurrencyIntent(amount: 100, rate: 0.92, currencyCode: "eur").perform()
        await #expect(throws: TaskLensError.self) {
            _ = try await ConvertCurrencyIntent(amount: 100, rate: 0).perform()
        }
        #expect(ConvertCurrencyIntent.decimal(1.1) == Decimal(string: "1.1"))
        #expect(ConvertCurrencyIntent.format(12.5, currencyCode: "nope") == (12.5 as Decimal).formatted(.number.precision(.fractionLength(0...4))))
    }

    @Test func entityQueriesFindWorkspacesAndSessions() async throws {
        let trip = try await container.workspaces.create(name: "Trip")
        _ = try await container.workspaces.create(name: "Thesis")
        let session = try await container.sessions.start(in: trip.id, title: "Flights")

        let workspaces = try await WorkspaceEntityQuery().entities(matching: "tri")
        #expect(workspaces.map(\.name) == ["Trip"])
        #expect(try await WorkspaceEntityQuery().suggestedEntities().count == 2)
        #expect(try await WorkspaceEntityQuery().entities(for: [trip.id.rawValue]).map(\.id) == [trip.id.rawValue])

        let sessions = try await SessionEntityQuery().entities(matching: "flight")
        #expect(sessions.map(\.id) == [session.id.rawValue])
        #expect(sessions.first?.workspaceName == "Trip")
    }
}

@MainActor
@Suite("Intent navigation")
struct IntentNavigatorTests {
    @Test func linksAreTakenOnce() {
        let navigator = IntentNavigator()
        #expect(navigator.take() == nil)
        navigator.open(DeepLink.clipboard)
        #expect(navigator.pendingURL == DeepLink.clipboard)
        #expect(navigator.take() == DeepLink.clipboard)
        #expect(navigator.take() == nil)
    }
}

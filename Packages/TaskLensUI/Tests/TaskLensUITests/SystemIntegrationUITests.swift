import Foundation
import Testing
import TLCoreServices
import TLDomain
import TLNavigation
import WidgetKit
@testable import WidgetsFeature

@Suite("Deep links")
struct DeepLinkTests {
    @Test func toolLinksRoundTrip() {
        #expect(DeepLink.route(for: DeepLink.lens)?.route == .lens)
        #expect(DeepLink.route(for: DeepLink.clipboard)?.route == .clipboard)
        #expect(DeepLink.route(for: DeepLink.notes)?.route == .notes(nil))
        #expect(DeepLink.route(for: DeepLink.calculator)?.route == .calculator(nil))
        #expect(DeepLink.route(for: DeepLink.pip)?.route == .pip)
        #expect(DeepLink.route(for: DeepLink.lens)?.tab == .commandCenter)
    }

    @Test func tabLinksHaveNoRoute() throws {
        let center = try #require(DeepLink.route(for: DeepLink.commandCenter))
        #expect(center.route == nil && center.tab == .commandCenter)
        let workspaces = try #require(DeepLink.route(for: DeepLink.workspaces))
        #expect(workspaces.route == nil && workspaces.tab == .workspaces)
    }

    @Test func workspaceAndSessionLinksRoundTrip() {
        let workspace = WorkspaceID()
        let session = SessionID()
        #expect(DeepLink.route(for: DeepLink.workspace(workspace))?.route == .workspace(workspace))
        #expect(DeepLink.route(for: DeepLink.session(session))?.route == .session(session))
        #expect(DeepLink.route(for: DeepLink.resume(session))?.route == .sessionResume(session))
        #expect(DeepLink.route(for: DeepLink.resume(session))?.tab == .workspaces)
        #expect(DeepLink.resume(session).absoluteString == "tasklens://session/\(session.uuidString)/resume")
    }

    @Test func lensTextIsCarriedAndCapped() {
        let text = "Meet at 5pm & call +1 555 0100 — ممتاز؟"
        #expect(DeepLink.route(for: DeepLink.lens(text: text))?.route == .lensInput(text))

        let long = String(repeating: "a", count: DeepLink.maximumTextLength + 50)
        #expect(DeepLink.route(for: DeepLink.lens(text: long))?.route == .lensInput(String(long.prefix(DeepLink.maximumTextLength))))

        // Blank text just opens Lens.
        #expect(DeepLink.route(for: DeepLink.lens(text: "   "))?.route == .lens)
    }

    @Test(arguments: [
        "https://tasklens.app/lens",
        "tasklens://unknown",
        "tasklens://workspace/not-a-uuid",
        "tasklens://session",
        "tasklens://session/\(UUID().uuidString)/delete",
        "tasklens://lens/extra",
        "other://lens",
    ])
    func malformedLinksOpenNothing(link: String) throws {
        let url = try #require(URL(string: link))
        #expect(DeepLink.route(for: url) == nil)
    }

    @Test func schemeAndHostAreCaseInsensitive() throws {
        let url = try #require(URL(string: "TaskLens://Clipboard"))
        #expect(DeepLink.route(for: url)?.route == .clipboard)
    }

    @MainActor
    @Test func routerOpensLinks() {
        let router = AppRouter(selectedTab: .settings)
        let session = SessionID()
        #expect(router.open(DeepLink.resume(session)))
        #expect(router.selectedTab == .workspaces)
        #expect(router.workspacesPath == [.sessionResume(session)])

        router.commandCenterPath = [.lens, .clipboard]
        #expect(router.open(DeepLink.commandCenter))
        #expect(router.selectedTab == .commandCenter)
        #expect(router.commandCenterPath.isEmpty)

        #expect(!router.open(URL(string: "tasklens://nope")!))
        #expect(router.selectedTab == .commandCenter)
    }
}

@Suite("Widget timeline")
struct WidgetTimelineTests {
    @Test func oneEntryWithASafetyRefresh() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let snapshot = WidgetSnapshot(generatedAt: now)
        let timeline = TaskLensTimeline.timeline(snapshot: snapshot, now: now)
        #expect(timeline.entries.count == 1)
        #expect(timeline.entries.first?.snapshot == snapshot)
        #expect(timeline.entries.first?.isPlaceholder == false)
        #expect(timeline.policy == .after(now.addingTimeInterval(TaskLensTimeline.refreshInterval)))
    }

    @Test func placeholderUsesSampleContent() {
        let entry = TaskLensTimeline.placeholder(now: Date(timeIntervalSinceReferenceDate: 0))
        #expect(entry.isPlaceholder)
        #expect(entry.snapshot.featuredWorkspace?.kind == .research)
        #expect(entry.snapshot.sessions.count == 1)
    }

    @Test func everyQuickActionOpensItsTool() {
        for destination in WidgetDestination.allCases {
            let route = DeepLink.route(for: destination.url)?.route
            switch destination {
            case .lens: #expect(route == .lens)
            case .clipboard: #expect(route == .clipboard)
            case .notes: #expect(route == .notes(nil))
            case .calculator: #expect(route == .calculator(nil))
            }
            #expect(!destination.symbolName.isEmpty)
        }
    }
}

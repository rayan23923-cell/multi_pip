import Foundation
import Testing
import TLDomain
@testable import TLNavigation

@MainActor
@Suite("AppRouter")
struct RouterTests {
    @Test func pushTargetsSelectedTab() {
        let router = AppRouter(selectedTab: .workspaces)
        let workspace = WorkspaceID()
        router.push(.workspace(workspace))
        #expect(router.workspacesPath == [.workspace(workspace)])
        #expect(router.commandCenterPath.isEmpty)
    }

    @Test func openSwitchesTabAndReplacesStack() {
        let router = AppRouter()
        router.push(.workspace(WorkspaceID()))
        let session = SessionID()
        router.open(.session(session), in: .workspaces)
        #expect(router.selectedTab == .workspaces)
        #expect(router.workspacesPath == [.session(session)])
    }

    @Test func popToRootClearsOnlyThatTab() {
        let router = AppRouter()
        router.commandCenterPath = [.session(SessionID())]
        router.workspacesPath = [.workspace(WorkspaceID())]
        router.popToRoot(.commandCenter)
        #expect(router.commandCenterPath.isEmpty)
        #expect(router.workspacesPath.count == 1)
    }
}

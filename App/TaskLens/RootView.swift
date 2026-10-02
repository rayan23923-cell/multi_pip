import CommandCenterFeature
import SessionsFeature
import SettingsFeature
import SwiftUI
import TLLocalization
import TLNavigation
import WorkspacesFeature

struct RootView: View {
    let container: AppContainer
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            NavigationStack(path: $router.commandCenterPath) {
                CommandCenterView(model: CommandCenterModel(
                    workspaceService: container.workspaces,
                    sessionService: container.sessions,
                    captureService: container.capture
                ))
                .withAppDestinations(container)
            }
            .tabItem { tabLabel(.tabCommandCenter, systemImage: "sparkle.magnifyingglass") }
            .tag(AppTab.commandCenter)

            NavigationStack(path: $router.workspacesPath) {
                WorkspaceListView(model: WorkspaceListModel(service: container.workspaces))
                    .withAppDestinations(container)
            }
            .tabItem { tabLabel(.tabWorkspaces, systemImage: "square.grid.2x2") }
            .tag(AppTab.workspaces)

            NavigationStack(path: $router.settingsPath) {
                SettingsView(version: AppContainer.appVersion, storage: container.storage)
                    .withAppDestinations(container)
            }
            .tabItem { tabLabel(.tabSettings, systemImage: "gearshape") }
            .tag(AppTab.settings)
        }
    }

    private func tabLabel(_ key: L10nKey, systemImage: String) -> some View {
        Label {
            Text(key)
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

private extension View {
    /// Maps routes to feature screens. Kept in the app so features stay independent.
    func withAppDestinations(_ container: AppContainer) -> some View {
        navigationDestination(for: AppRoute.self) { route in
            switch route {
            case .workspace(let id):
                WorkspaceDetailView(model: WorkspaceDetailModel(
                    workspaceID: id,
                    workspaceService: container.workspaces,
                    sessionService: container.sessions
                ))
            case .session(let id):
                SessionDetailView(model: SessionDetailModel(
                    sessionID: id,
                    sessionService: container.sessions,
                    captureService: container.capture
                ))
            }
        }
    }
}

#Preview {
    RootView(container: .preview())
        .environment(AppRouter())
}

import SwiftUI
import PiPFeature
import TLNavigation

@main
struct TaskLensApp: App {
    @State private var container: AppContainer
    @State private var router = AppRouter()
    @State private var pip: PiPWorkspaceModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container = AppContainer.live()
        _container = State(initialValue: container)
        _pip = State(initialValue: RootView.makePiP(container: container))
    }

    var body: some Scene {
        WindowGroup {
            if ShareHarness.isRequested() {
                ShareHarnessView(container: container)
            } else {
                RootView(container: container, pip: pip)
                    .environment(router)
                    .task { await SampleDocuments.seedIfRequested(container.documents) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Items shared from other apps wait in the outbox until the app is active.
            if phase == .active {
                Task { await container.deliverSharedItems() }
            }
        }
    }
}

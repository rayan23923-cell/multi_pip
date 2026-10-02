import SwiftUI
import TLNavigation

@main
struct TaskLensApp: App {
    @State private var container = AppContainer.live()
    @State private var router = AppRouter()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if ShareHarness.isRequested() {
                ShareHarnessView(container: container)
            } else {
                RootView(container: container)
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

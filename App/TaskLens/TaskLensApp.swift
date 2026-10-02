import SwiftUI
import LensFeature
import LiveActivitiesFeature
import PiPFeature
import TLNavigation

@main
struct TaskLensApp: App {
    @State private var container: AppContainer
    @State private var router = AppRouter()
    @State private var pip: PiPWorkspaceModel
    @State private var liveActivities: LiveActivityController
    /// One Screen Lens per run, shared with every Lens screen and the Live Activity buttons.
    @State private var screenLens: ScreenLensModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The same container App Intents use, so both see one store.
        let container = AppContainer.shared
        _container = State(initialValue: container)
        _pip = State(initialValue: RootView.makePiP(container: container))
        _liveActivities = State(initialValue: LiveActivityController(
            service: container.sessionActivities,
            client: ActivityKitLiveActivityClient()
        ))
        _screenLens = State(initialValue: ScreenLensSetup.make(container: container))
    }

    var body: some Scene {
        WindowGroup {
            if ShareHarness.isRequested() {
                ShareHarnessView(container: container)
            } else {
                RootView(container: container, pip: pip)
                    .environment(router)
                    .environment(screenLens)
                    .task {
                        // A capture can't outlive the process: remove a status left by a closed run.
                        await ActivityKitScreenLensStatus.endLeftovers()
                    }
                    .task { await SampleDocuments.seedIfRequested(container.documents) }
                    .task {
                        // Live Activities and widgets follow every session change.
                        await liveActivities.follow(container.storeChanges) {
                            await container.refreshWidgets()
                        }
                    }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                screenLens.tick()
                // Items shared from other apps wait in the outbox until the app is active.
                Task {
                    await container.deliverSharedItems()
                    // Also cleans up activities left from a previous run.
                    await liveActivities.refresh()
                    await container.refreshWidgets()
                }
            case .background:
                // Widgets show what changed while the app was open.
                Task { await container.refreshWidgets() }
            default:
                break
            }
        }
    }
}

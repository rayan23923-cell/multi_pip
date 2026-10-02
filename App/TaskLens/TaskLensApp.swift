import SwiftUI
import LensFeature
import LiveActivitiesFeature
import PiPFeature
import TLNavigation
import WorkflowsFeature

@main
struct TaskLensApp: App {
    @State private var container: AppContainer
    @State private var router = AppRouter()
    @State private var pip: PiPWorkspaceModel
    @State private var liveActivities: LiveActivityController
    /// One Screen Lens per run, shared with every Lens screen and the Live Activity buttons.
    @State private var screenLens: ScreenLensModel
    /// Workflows, and the runs shared items started that wait for the user's OK.
    @State private var workflows: WorkflowsModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The same container App Intents use, so both see one store.
        // Crash and hang reports from iOS go to the device log only.
        CrashDiagnostics.shared.start()
        let container = AppContainer.shared
        _container = State(initialValue: container)
        _pip = State(initialValue: RootView.makePiP(container: container))
        _liveActivities = State(initialValue: LiveActivityController(
            service: container.sessionActivities,
            client: ActivityKitLiveActivityClient()
        ))
        _screenLens = State(initialValue: ScreenLensSetup.make(container: container))
        _workflows = State(initialValue: WorkflowsModel(
            service: container.workflows, runner: container.workflowRunner, automation: container.workflowAutomation
        ))
    }

    var body: some Scene {
        WindowGroup {
            if ShareHarness.isRequested() {
                ShareHarnessView(container: container)
            } else {
                RootView(container: container, pip: pip)
                    .environment(router)
                    .environment(screenLens)
                    .environment(workflows)
                    .task {
                        // A capture can't outlive the process: remove a status left by a closed run.
                        await ActivityKitScreenLensStatus.endLeftovers()
                    }
                    .task { await SampleDocuments.seedIfRequested(container.documents) }
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                        container.handleMemoryWarning()
                    }
                    #if DEBUG
                    .task {
                        // UI tests: the same notification iOS sends when memory is low.
                        guard ProcessInfo.processInfo.arguments.contains("-TaskLensMemoryWarning") else { return }
                        try? await Task.sleep(for: .seconds(1))
                        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: UIApplication.shared)
                    }
                    #endif
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
                    let shared = await container.deliverSharedItems()
                    // Workflows the user turned on for shared content.
                    await workflows.handleShared(shared)
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

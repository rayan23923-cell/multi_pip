import SwiftUI
import TLNavigation

@main
struct TaskLensApp: App {
    @State private var container = AppContainer.live()
    @State private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootView(container: container)
                .environment(router)
                .task { await SampleDocuments.seedIfRequested(container.documents) }
        }
    }
}

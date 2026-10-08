import SwiftUI

@main
struct IslamicPiPPOCApp: App {
    @StateObject private var engine = PiPEngine()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
        }
        .onChange(of: scenePhase) { phase in
            engine.log("scenePhase -> \(phase)")
        }
    }
}

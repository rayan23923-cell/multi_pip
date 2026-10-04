import SwiftUI

/// Host app for the probe tests; WebKit and Quick Look need a window.
@main
struct ProbeApp: App {
    var body: some Scene {
        WindowGroup { Color.white }
    }
}

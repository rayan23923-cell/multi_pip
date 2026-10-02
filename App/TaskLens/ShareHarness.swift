import Foundation
import ShareFeature
import SwiftUI
import TLCoreServices

/// Runs the share sheet screens inside the app with real `NSItemProvider`s.
/// Only used with the `-TaskLensShareHarness` launch argument, by UI tests:
/// iOS does not offer an app's own share extension in that app's share sheet,
/// so this drives the same `ShareView`, intake and outbox end to end, then
/// delivers the outbox into the store exactly as the app does on launch.
enum ShareHarness {
    static let launchArgument = "-TaskLensShareHarness"

    static func isRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(launchArgument)
    }

    /// Phone text, a link, a PDF, a PNG and one unsupported item.
    @MainActor
    static func makeModel(container: AppContainer) -> ShareModel {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("ShareHarness-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try? fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        let pdf = source.appendingPathComponent("Sample Report.pdf")
        let png = source.appendingPathComponent("Sample Image.png")
        try? SampleDocuments.pdf().write(to: pdf)
        try? SampleDocuments.image().write(to: png)

        var providers: [NSItemProvider] = [
            NSItemProvider(object: "+964 770 123 4567" as NSString),
            NSItemProvider(object: URL(string: "https://example.com/offer")! as NSURL),
        ]
        if let provider = NSItemProvider(contentsOf: pdf) { providers.append(provider) }
        if let provider = NSItemProvider(contentsOf: png) { providers.append(provider) }
        providers.append(NSItemProvider(item: Data([1, 2, 3]) as NSData, typeIdentifier: "com.example.unsupported"))

        return ShareModel(
            providers: providers,
            workingDirectory: root.appendingPathComponent("intake", isDirectory: true),
            outbox: container.shareOutbox,
            sessionService: container.sessions
        )
    }
}

/// Test-only host for `ShareView`. Shows the outcome as plain text for UI tests.
struct ShareHarnessView: View {
    let container: AppContainer
    @State private var model: ShareModel?
    @State private var outcome: String?

    var body: some View {
        Group {
            if let outcome {
                Text(verbatim: outcome)
                    .accessibilityIdentifier("harness.outcome")
            } else if let model {
                ShareView(model: model)
            } else {
                ProgressView()
            }
        }
        .task {
            guard model == nil else { return }
            if let workspace = try? await container.workspaces.create(name: "Shared") {
                _ = try? await container.sessions.start(in: workspace.id)
            }
            let model = ShareHarness.makeModel(container: container)
            model.onFinish = { result in
                Task { @MainActor in
                    switch result {
                    case .cancelled:
                        outcome = "cancelled"
                    case .saved(let count):
                        let delivered = await container.deliverSharedItems()
                        outcome = "saved \(count) delivered \(delivered)"
                    }
                }
            }
            self.model = model
        }
    }
}

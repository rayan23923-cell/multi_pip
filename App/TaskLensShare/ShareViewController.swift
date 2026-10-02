import ShareFeature
import SwiftUI
import TLCoreServices
import TLData
import TLFoundation
import UIKit

/// Entry point of the TaskLens share extension.
///
/// The extension reads the shared items, runs the Context and Action Engines
/// on them, and drops what the user saves into the shared outbox. It reads the
/// app's store only to list sessions and never writes it; the app saves the
/// outbox into sessions the next time it becomes active.
final class ShareViewController: UIViewController {
    private var model: ShareModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        let logger = TLLogger(category: "share")
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let providers = ShareIntake.providers(in: items)

        let groupIdentifier = Bundle.main.object(forInfoDictionaryKey: "TLAppGroupIdentifier") as? String
        let location = try? StoreLocation.resolve(appGroupIdentifier: groupIdentifier, logger: logger)
        var sessionService: SessionService?
        if let location, let repositories = try? Repositories.fileBacked(at: location, logger: logger.scoped("persistence")) {
            sessionService = SessionService(
                workspaces: repositories.workspaces,
                sessions: repositories.sessions,
                clock: SystemDateProvider(),
                logger: logger.scoped("sessions")
            )
        }
        let fileManager = FileManager.default
        let outbox = ShareOutbox(storeRoot: location?.rootURL ?? fileManager.temporaryDirectory)
        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ShareIntake-\(UUID().uuidString)", isDirectory: true)
        logger.info("Share started with \(providers.count) item(s); store: \(location?.kind.rawValue ?? "none")")

        let model = ShareModel(
            providers: providers,
            workingDirectory: workingDirectory,
            outbox: outbox,
            sessionService: sessionService
        )
        model.onFinish = { [weak self] outcome in
            guard let context = self?.extensionContext else { return }
            switch outcome {
            case .saved:
                context.completeRequest(returningItems: nil)
            case .cancelled:
                context.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            }
        }
        self.model = model

        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }
}

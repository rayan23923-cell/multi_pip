import AppIntents
import WidgetsFeature

// Compiled into both the app and the widget extension: the widget's buttons
// name this intent, and iOS runs it in the app (it opens TaskLens), where
// `TASKLENS_APP` is defined and the link reaches the UI.

/// The TaskLens tools a small widget button can open.
enum QuickDestination: String, AppEnum {
    case lens
    case clipboard
    case notes
    case calculator

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "intent.type.destination")
    static let caseDisplayRepresentations: [QuickDestination: DisplayRepresentation] = [
        .lens: "intent.destination.lens",
        .clipboard: "intent.destination.clipboard",
        .notes: "intent.destination.notes",
        .calculator: "intent.destination.calculator",
    ]

    init(_ destination: WidgetDestination) {
        switch destination {
        case .lens: self = .lens
        case .clipboard: self = .clipboard
        case .notes: self = .notes
        case .calculator: self = .calculator
        }
    }

    var destination: WidgetDestination {
        switch self {
        case .lens: .lens
        case .clipboard: .clipboard
        case .notes: .notes
        case .calculator: .calculator
        }
    }
}

/// Opens a TaskLens tool from a widget button.
struct OpenDestinationIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.openDestination.title"
    static let openAppWhenRun = true
    /// Only for widget buttons; Siri and Shortcuts have their own intents.
    static let isDiscoverable = false

    @Parameter(title: "intent.param.destination")
    var destination: QuickDestination

    init() {}

    init(_ destination: WidgetDestination) {
        self.destination = QuickDestination(destination)
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if TASKLENS_APP
        IntentDependencies.navigator.open(destination.destination.url)
        #endif
        return .result()
    }
}

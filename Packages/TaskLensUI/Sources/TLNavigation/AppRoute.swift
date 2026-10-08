import Foundation
import Observation
import TLDomain

/// Top-level tabs.
public enum AppTab: String, Hashable, CaseIterable, Sendable {
    case commandCenter
    case workspaces
    case settings
}

/// Every pushable destination. Features push values; the app decides which
/// view renders each route, so features never import each other.
public enum AppRoute: Hashable, Sendable {
    case workspace(WorkspaceID)
    case session(SessionID)
    /// A session opened with Resume: it becomes active again and shows where the user stopped.
    case sessionResume(SessionID)
    case lens
    case clipboard
    /// Lens pre-filled with content another tool sent to the Action Engine.
    case lensInput(String)
    /// Lens reading an image or PDF on the device (from a viewer or shared content).
    case lensFile(URL)
    /// Tools. The workspace, when given, scopes lists and picks the session to save to.
    case notes(WorkspaceID?)
    /// Notes with the editor open on a new note holding this text.
    case noteDraft(String)
    /// Notes with this note open (Resume).
    case note(NoteID)
    case calculator(WorkspaceID?)
    /// Calculator starting from a value the Action Engine found (a price, a number).
    case calculatorInput(Decimal)
    case browser(WorkspaceID?)
    /// The browser opening this page in a new tab (Resume).
    case browserPage(URL)
    /// Picture in Picture: the cards kept in view and the start/stop controls.
    case pip
    /// Workflows: what runs on shared content, and what the user runs.
    case workflows
    case documents(WorkspaceID?)
    /// Viewers, chosen by document kind.
    case pdf(DocumentID)
    case image(DocumentID)
    case textDocument(DocumentID)
    /// An imported PowerPoint file.
    case powerPoint(DocumentID)
    /// A PDF or a set of images shown one slide at a time.
    case presentation(PresentationRequest)
}

/// What to present. Images keep the order given.
public enum PresentationRequest: Hashable, Sendable {
    case pdf(DocumentID)
    case images([DocumentID])
    /// An imported PowerPoint file, shown from its rendered slide images.
    case powerPoint(DocumentID)
}

extension AppRoute {
    /// Where to continue after Resume, from the last tool position.
    /// Nil when nothing was recorded or the tool has no position to return to.
    public static func resuming(_ state: SessionResumeState, workspaceID: WorkspaceID?) -> AppRoute? {
        switch state.tool {
        case .browser: state.url.map(AppRoute.browserPage)
        case .documents: state.documentID.map(AppRoute.pdf)
        case .notes: state.noteID.map(AppRoute.note) ?? .notes(workspaceID)
        default: tool(state.tool, workspaceID: workspaceID)
        }
    }

    /// Where Picture in Picture returns to when the user taps its window (Restore).
    public static func restoring(_ card: PiPCard) -> AppRoute {
        let origin = card.origin
        if let noteID = origin.noteID { return .note(noteID) }
        if let documentID = origin.documentID { return .pdf(documentID) }
        if let sessionID = origin.sessionID { return .session(sessionID) }
        if card.kind == .calculation { return .calculator(card.workspaceID) }
        return .pip
    }

    /// The viewer route for a document.
    public static func viewer(for document: Document) -> AppRoute {
        switch document.kind {
        case .pdf, .document: .pdf(document.id)
        case .image: .image(document.id)
        case .text: .textDocument(document.id)
        case .powerpoint: .powerPoint(document.id)
        }
    }

    /// The screen for a workspace tool.
    public static func tool(_ tool: WorkspaceTool, workspaceID: WorkspaceID?) -> AppRoute? {
        switch tool {
        case .lens: .lens
        case .clipboard: .clipboard
        case .notes: .notes(workspaceID)
        case .calculator: .calculator(workspaceID)
        case .browser: .browser(workspaceID)
        case .documents: .documents(workspaceID)
        default: nil
        }
    }
}

/// Owns tab selection and one navigation stack per tab.
@MainActor
@Observable
public final class AppRouter {
    public var selectedTab: AppTab
    public var commandCenterPath: [AppRoute] = []
    public var workspacesPath: [AppRoute] = []
    public var settingsPath: [AppRoute] = []
    /// A search the Command Center should run when it appears (Search action).
    public var pendingSearch: String?
    /// Content a screen asked to keep in Picture in Picture; the app adds it
    /// to the Picture in Picture cards and shows them.
    public var pendingPiP: PiPRequest?

    public init(selectedTab: AppTab = .commandCenter) {
        self.selectedTab = selectedTab
    }

    /// Pushes a route on the currently selected tab.
    public func push(_ route: AppRoute) {
        append(route, to: selectedTab)
    }

    /// Replaces the screen on top of the selected tab, so Back goes where it
    /// went from the replaced screen. Pushes when the tab shows its root.
    public func replaceTop(with route: AppRoute) {
        let current = path(for: selectedTab)
        setPath(Array(current.dropLast()) + [route], for: selectedTab)
    }

    /// Switches tab and shows `route` on top of that tab's root (deep links, intents).
    public func open(_ route: AppRoute, in tab: AppTab) {
        selectedTab = tab
        setPath([route], for: tab)
    }

    /// Resume: the session inside its workspace, on the Workspaces tab.
    public func resume(_ session: Session) {
        selectedTab = .workspaces
        setPath([.workspace(session.workspaceID), .sessionResume(session.id)], for: .workspaces)
    }

    /// Shows the Command Center searching saved content for `query`.
    public func search(_ query: String) {
        pendingSearch = query
        selectedTab = .commandCenter
        setPath([], for: .commandCenter)
    }

    /// Keeps content in Picture in Picture (Keep in Picture in Picture).
    public func keepInPiP(_ request: PiPRequest) {
        pendingPiP = request
    }

    public func popToRoot(_ tab: AppTab? = nil) {
        setPath([], for: tab ?? selectedTab)
    }

    public func path(for tab: AppTab) -> [AppRoute] {
        switch tab {
        case .commandCenter: commandCenterPath
        case .workspaces: workspacesPath
        case .settings: settingsPath
        }
    }

    private func append(_ route: AppRoute, to tab: AppTab) {
        setPath(path(for: tab) + [route], for: tab)
    }

    private func setPath(_ path: [AppRoute], for tab: AppTab) {
        switch tab {
        case .commandCenter: commandCenterPath = path
        case .workspaces: workspacesPath = path
        case .settings: settingsPath = path
        }
    }
}

/// Content to keep in Picture in Picture.
public enum PiPRequest: Equatable, Sendable {
    /// What a tool shows now (a note, a page, a result).
    case output(ToolOutput, workspaceID: WorkspaceID?)
    /// An item saved in a session.
    case item(ContextItem)
}

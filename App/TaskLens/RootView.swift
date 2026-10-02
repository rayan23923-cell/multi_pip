import BrowserFeature
import CalculatorFeature
import ClipboardFeature
import CommandCenterFeature
import DocumentsFeature
import ImageViewerFeature
import LensFeature
import NotesFeature
import SessionsFeature
import SettingsFeature
import SwiftUI
import TextViewerFeature
import TLLocalization
import TLNavigation
import WorkspacesFeature

struct RootView: View {
    let container: AppContainer
    @Environment(AppRouter.self) private var router
    /// Shared so browser tabs survive leaving the browser screen.
    @State private var browser: BrowserModel

    init(container: AppContainer) {
        self.container = container
        _browser = State(initialValue: BrowserModel(toolCapture: container.toolCapture))
    }

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            NavigationStack(path: $router.commandCenterPath) {
                CommandCenterView(model: CommandCenterModel(
                    workspaceService: container.workspaces,
                    sessionService: container.sessions,
                    captureService: container.capture,
                    searchService: container.search
                ))
                .withAppDestinations(container, browser: browser)
            }
            .tabItem { tabLabel(.tabCommandCenter, systemImage: "sparkle.magnifyingglass") }
            .tag(AppTab.commandCenter)

            NavigationStack(path: $router.workspacesPath) {
                WorkspaceListView(model: WorkspaceListModel(service: container.workspaces))
                    .withAppDestinations(container, browser: browser)
            }
            .tabItem { tabLabel(.tabWorkspaces, systemImage: "square.grid.2x2") }
            .tag(AppTab.workspaces)

            NavigationStack(path: $router.settingsPath) {
                SettingsView(version: AppContainer.appVersion, storage: container.storage)
                    .withAppDestinations(container, browser: browser)
            }
            .tabItem { tabLabel(.tabSettings, systemImage: "gearshape") }
            .tag(AppTab.settings)
        }
    }

    private func tabLabel(_ key: L10nKey, systemImage: String) -> some View {
        Label {
            Text(key)
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

private extension View {
    /// Maps routes to feature screens. Kept in the app so features stay independent.
    func withAppDestinations(_ container: AppContainer, browser: BrowserModel) -> some View {
        navigationDestination(for: AppRoute.self) { route in
            switch route {
            case .workspace(let id):
                WorkspaceDetailView(model: WorkspaceDetailModel(
                    workspaceID: id,
                    workspaceService: container.workspaces,
                    sessionService: container.sessions
                ))
            case .session(let id):
                SessionDetailView(model: SessionDetailModel(
                    sessionID: id,
                    sessionService: container.sessions,
                    captureService: container.capture
                ))
            case .lens:
                LensView(model: LensModel(captureService: container.capture, sessionService: container.sessions))
            case .clipboard:
                ClipboardView(model: ClipboardModel(clipboardService: container.clipboard, sessionService: container.sessions))
            case .lensInput(let input):
                LensView(model: LensModel(
                    captureService: container.capture,
                    sessionService: container.sessions,
                    initialInput: input
                ))
            case .notes(let workspaceID):
                NotesView(model: NotesModel(
                    workspaceID: workspaceID,
                    noteService: container.notes,
                    toolCapture: container.toolCapture
                ))
            case .noteDraft(let text):
                NotesView(model: NotesModel(
                    workspaceID: nil,
                    noteService: container.notes,
                    toolCapture: container.toolCapture
                ), draft: text)
            case .calculator(let workspaceID):
                CalculatorView(model: CalculatorModel(
                    workspaceID: workspaceID,
                    calculatorService: container.calculator,
                    toolCapture: container.toolCapture
                ))
            case .calculatorInput(let value):
                CalculatorView(model: CalculatorModel(
                    workspaceID: nil,
                    calculatorService: container.calculator,
                    toolCapture: container.toolCapture,
                    initialValue: value
                ))
            case .browser(let workspaceID):
                BrowserView(model: browser)
                    .onAppear { browser.workspaceID = workspaceID }
            case .documents(let workspaceID):
                DocumentLibraryView(model: DocumentLibraryModel(
                    workspaceID: workspaceID,
                    documentService: container.documents,
                    sessionService: container.sessions
                ))
            case .pdf(let id):
                PDFViewerView(model: PDFViewerModel(
                    documentID: id,
                    documentService: container.documents,
                    toolCapture: container.toolCapture
                ))
            case .image(let id):
                ImageViewerView(model: ImageViewerModel(
                    documentID: id,
                    documentService: container.documents,
                    toolCapture: container.toolCapture
                ))
            case .textDocument(let id):
                TextViewerView(model: TextViewerModel(
                    documentID: id,
                    documentService: container.documents,
                    toolCapture: container.toolCapture
                ))
            }
        }
    }
}

#Preview("Light") {
    RootView(container: .preview())
        .environment(AppRouter())
}

#Preview("Dark, Arabic, RTL") {
    RootView(container: .preview())
        .environment(AppRouter())
        .environment(\.locale, Locale(identifier: "ar"))
        .environment(\.layoutDirection, .rightToLeft)
        .preferredColorScheme(.dark)
}

#Preview("Accessibility text size") {
    RootView(container: .preview())
        .environment(AppRouter())
        .dynamicTypeSize(.accessibility3)
}

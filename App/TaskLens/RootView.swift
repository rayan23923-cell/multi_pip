import AIFeature
import TLCoreServices
import BrowserFeature
import CalculatorFeature
import ClipboardFeature
import CommandCenterFeature
import DocumentsFeature
import ImageViewerFeature
import LensFeature
import NotesFeature
import PiPFeature
import PresentationFeature
import SessionsFeature
import SettingsFeature
import SwiftUI
import TextViewerFeature
import TLLocalization
import TLNavigation
import WorkflowsFeature
import WorkspacesFeature

struct RootView: View {
    let container: AppContainer
    @Environment(AppRouter.self) private var router
    /// Shared so browser tabs survive leaving the browser screen.
    @State private var browser: BrowserModel
    /// Owned by the app so the Picture in Picture window outlives any one screen.
    let pip: PiPWorkspaceModel
    /// Screens App Intents asked to open.
    let navigator: IntentNavigator
    @State private var aiSettings: AISettingsModel
    @State private var dataControl: DataControlModel
    @Environment(WorkflowsModel.self) private var workflows: WorkflowsModel?
    /// Used only when no model was injected (previews, the share harness).
    @State private var fallbackWorkflows: WorkflowsModel

    init(container: AppContainer, pip: PiPWorkspaceModel, navigator: IntentNavigator = .shared) {
        self.container = container
        self.pip = pip
        self.navigator = navigator
        let browser = BrowserModel(toolCapture: container.toolCapture)
        browser.stateRecorder = container.toolState
        _browser = State(initialValue: browser)
        _aiSettings = State(initialValue: AISettingsModel(service: container.ai, secrets: container.aiSecrets))
        _fallbackWorkflows = State(initialValue: WorkflowsModel(service: container.workflows, runner: container.workflowRunner))
        _dataControl = State(initialValue: DataControlModel(
            export: { try await container.exportData() },
            deleteEverything: { try await container.deleteEverything() }
        ))
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
                .withAppDestinations(container, browser: browser, pip: pip, workflows: workflows ?? fallbackWorkflows)
            }
            .tabItem { tabLabel(.tabCommandCenter, systemImage: "sparkle.magnifyingglass") }
            .tag(AppTab.commandCenter)

            NavigationStack(path: $router.workspacesPath) {
                WorkspaceListView(model: WorkspaceListModel(service: container.workspaces))
                    .withAppDestinations(container, browser: browser, pip: pip, workflows: workflows ?? fallbackWorkflows)
            }
            .tabItem { tabLabel(.tabWorkspaces, systemImage: "square.grid.2x2") }
            .tag(AppTab.workspaces)

            NavigationStack(path: $router.settingsPath) {
                SettingsView(version: AppContainer.appVersion, storage: container.storage, ai: aiSettings, data: dataControl)
                    .onAppear {
                        // Nothing deleted may stay on screen in other tabs.
                        dataControl.onDeleted = { [appRouter = self.router, aiSettings] in
                            appRouter.commandCenterPath = []
                            appRouter.workspacesPath = []
                            Task { await aiSettings.load() }
                        }
                    }
                    .withAppDestinations(container, browser: browser, pip: pip, workflows: workflows ?? fallbackWorkflows)
            }
            .tabItem { tabLabel(.tabSettings, systemImage: "gearshape") }
            .tag(AppTab.settings)
        }
        .task {
            pip.onRestore = { card in
                // The user tapped the window: show what the card came from.
                let route = AppRoute.restoring(card)
                if router.path(for: router.selectedTab).last != route { router.push(route) }
            }
            await pip.load(afterLaunch: true)
        }
        // tasklens:// links from widgets, App Shortcuts and Live Activities.
        .onOpenURL { url in
            router.open(url)
        }
        .task {
            // An intent that launched the app may have run before this view existed.
            if let url = navigator.take() { router.open(url) }
        }
        .onChange(of: navigator.pendingURL) { _, url in
            guard url != nil, let url = navigator.take() else { return }
            router.open(url)
        }
        .onChange(of: router.pendingPiP) { _, request in
            guard let request else { return }
            router.pendingPiP = nil
            Task {
                switch request {
                case .output(let output, let workspaceID): await pip.keep(output, workspaceID: workspaceID)
                case .item(let item): await pip.keep(item)
                }
                if router.path(for: router.selectedTab).last != .pip { router.push(.pip) }
            }
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

extension RootView {
    /// Created once per app run: AVKit allows one Picture in Picture window.
    @MainActor
    static func makePiP(container: AppContainer, arguments: [String] = ProcessInfo.processInfo.arguments) -> PiPWorkspaceModel {
        let engine: any PictureInPictureEngine = arguments.contains("-TaskLensPiPUnsupported")
            ? UnavailablePictureInPictureEngine()
            : AVKitPictureInPictureEngine()
        return PiPWorkspaceModel(service: container.pip, engine: engine)
    }
}

private extension View {
    /// Maps routes to feature screens. Kept in the app so features stay independent.
    func withAppDestinations(_ container: AppContainer, browser: BrowserModel, pip: PiPWorkspaceModel, workflows: WorkflowsModel) -> some View {
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
                    contentService: container.sessionContent,
                    captureService: container.capture
                ))
            case .sessionResume(let id):
                SessionDetailView(model: SessionDetailModel(
                    sessionID: id,
                    sessionService: container.sessions,
                    contentService: container.sessionContent,
                    captureService: container.capture,
                    resume: true
                ))
            case .lens:
                LensView(model: container.makeLens())
            case .clipboard:
                ClipboardView(model: ClipboardModel(clipboardService: container.clipboard, sessionService: container.sessions))
            case .lensInput(let input):
                LensView(model: container.makeLens(initialInput: input))
            case .lensFile(let url):
                LensView(model: container.makeLens(), openingFile: url)
            case .notes(let workspaceID):
                NotesView(model: NotesModel(
                    workspaceID: workspaceID,
                    noteService: container.notes,
                    toolCapture: container.toolCapture,
                    stateRecorder: container.toolState
                ))
            case .note(let id):
                NotesView(model: NotesModel(
                    workspaceID: nil,
                    noteService: container.notes,
                    toolCapture: container.toolCapture,
                    stateRecorder: container.toolState
                ), openingNote: id)
            case .noteDraft(let text):
                NotesView(model: NotesModel(
                    workspaceID: nil,
                    noteService: container.notes,
                    toolCapture: container.toolCapture,
                    stateRecorder: container.toolState
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
            case .browserPage(let url):
                BrowserView(model: browser, opening: url)
            case .pip:
                PiPWorkspaceView(model: pip)
            case .workflows:
                WorkflowsView(model: workflows)
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
                    toolCapture: container.toolCapture,
                    stateRecorder: container.toolState
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
            case .powerPoint(let id):
                PowerPointDocumentView(documentID: id, documentService: container.documents)
            case .presentation(let request):
                PresentationView(model: PresentationModel(
                    request: request,
                    documentService: container.documents,
                    sessionStore: container.presentationSessions
                ))
            }
        }
    }
}

#Preview("Light") {
    RootView(container: .preview(), pip: RootView.makePiP(container: .preview()))
        .environment(AppRouter())
}

#Preview("Dark, Arabic, RTL") {
    RootView(container: .preview(), pip: RootView.makePiP(container: .preview()))
        .environment(AppRouter())
        .environment(\.locale, Locale(identifier: "ar"))
        .environment(\.layoutDirection, .rightToLeft)
        .preferredColorScheme(.dark)
}

#Preview("Accessibility text size") {
    RootView(container: .preview(), pip: RootView.makePiP(container: .preview()))
        .environment(AppRouter())
        .dynamicTypeSize(.accessibility3)
}

extension AppContainer {
    /// Lens with optional AI. AI may include the active session's item titles,
    /// only when the user turns that on for a request.
    @MainActor
    func makeLens(initialInput: String = "") -> LensModel {
        let sessions = self.sessions
        let capture = self.capture
        let ai = AIAssistModel(service: ai) {
            guard let session = try? await sessions.activeSessions().first,
                  let items = try? await capture.items(in: session.id) else { return [] }
            return items.prefix(AIRequestBuilder.maximumSessionItems).map { item in
                switch item.content {
                case .text(let text): String(text.prefix(200))
                case .url(let url): url.absoluteString
                case .file(let file): file.originalFilename ?? ""
                }
            }
        }
        return LensModel(captureService: capture, sessionService: sessions, initialInput: initialInput, ai: ai)
    }
}

import PDFKit
import SwiftUI
import TLDesignSystem
import TLDomain
import TLLocalization
import TLNavigation

public struct PDFViewerView: View {
    @State private var model: PDFViewerModel
    @State private var isSearching = false
    @State private var showsText = false
    @State private var isGoingToPage = false
    @State private var pageInput = ""
    @Environment(AppRouter.self) private var router

    public init(model: PDFViewerModel) {
        _model = State(initialValue: model)
    }

    /// Page navigation. Kept in the content rather than the bottom toolbar so
    /// it lays out (and is exposed to accessibility) the same on every iOS version.
    private var pageBar: some View {
        HStack {
            Button { model.previousPage() } label: {
                Image(systemName: "chevron.backward")
                    .accessibilityLabel(Text(L10nKey.pdfPreviousPage))
            }
            .disabled(!model.canGoBack)
            .accessibilityIdentifier("pdf.previousPage")
            Spacer()
            Text(L10n.format(.pdfPage, model.currentPage + 1, model.pageCount))
                .font(.footnote.monospacedDigit())
                .accessibilityIdentifier("pdf.pageLabel")
            Spacer()
            Button { model.nextPage() } label: {
                Image(systemName: "chevron.forward")
                    .accessibilityLabel(Text(L10nKey.pdfNextPage))
            }
            .disabled(!model.canGoForward)
            .accessibilityIdentifier("pdf.nextPage")
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
        .padding(.horizontal, TLSpacing.l)
        .padding(.vertical, TLSpacing.s)
        .background(.bar)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if isSearching {
                searchBar
                Divider()
            }
            if let pdf = model.pdf {
                PDFKitView(pdf: pdf, page: model.currentPage, highlight: model.currentMatch) { page in
                    model.pageDidChange(to: page)
                }
                .accessibilityIdentifier("pdf.view")
                Divider()
                pageBar
            } else if model.failedToOpen {
                TLEmptyState(title: .documentsOpenFailed, message: .documentsEmptyMessage, symbolName: "exclamationmark.triangle")
                    .frame(maxHeight: .infinity)
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .navigationTitle(model.document?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { isSearching.toggle() } label: {
                    TLLabel(.pdfSearchPrompt, systemImage: "magnifyingglass")
                }
                .accessibilityIdentifier("pdf.search")
                Menu {
                    Button { router.push(.presentation(.pdf(model.documentID))) } label: {
                        TLLabel(.presentationPresent, systemImage: "play.rectangle")
                    }
                    .accessibilityIdentifier("pdf.present")
                    Button {
                        model.extractCurrentPageText()
                        showsText = true
                    } label: {
                        TLLabel(.pdfExtractText, systemImage: "text.viewfinder")
                    }
                    .accessibilityIdentifier("pdf.extractText")
                    Button { Task { await model.saveDocument() } } label: {
                        TLLabel(.commonSaveToSession, systemImage: "tray.and.arrow.down")
                    }
                    .accessibilityIdentifier("pdf.save")
                    Button {
                        if let output = model.pageOutput {
                            router.keepInPiP(.output(output, workspaceID: model.document?.workspaceID))
                        }
                    } label: {
                        TLLabel(.pipKeep, systemImage: "pip.enter")
                    }
                    .accessibilityIdentifier("pdf.keepInPiP")
                    if let url = model.fileURL {
                        Button { router.push(.lensFile(url)) } label: {
                            TLLabel(.pdfLens, systemImage: "text.viewfinder")
                        }
                        .accessibilityIdentifier("pdf.lens")
                    }
                    if let url = model.fileURL {
                        ShareLink(item: url) { TLLabel(.actionShare, systemImage: "square.and.arrow.up") }
                    }
                    Button { isGoingToPage = true } label: {
                        TLLabel(.pdfGoToPage, systemImage: "arrow.right.doc.on.clipboard")
                    }
                } label: {
                    TLLabel(.commonMore, systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("pdf.menu")
            }
        }
        .sheet(isPresented: $showsText) {
            ExtractedTextSheet(model: model)
        }
        .alert(Text(L10nKey.pdfGoToPage), isPresented: $isGoingToPage) {
            TextField(String(model.currentPage + 1), text: $pageInput)
                .keyboardType(.numberPad)
            Button {
                if let page = Int(pageInput) { model.goTo(page: page - 1) }
                pageInput = ""
            } label: { Text(L10nKey.commonOk) }
            Button(role: .cancel) { pageInput = "" } label: { Text(L10nKey.commonCancel) }
        }
        .sensoryFeedback(.success, trigger: model.savedItemCount)
        .task { await model.load() }
        .errorAlert(message: $model.errorMessage)
    }

    private var searchBar: some View {
        HStack(spacing: TLSpacing.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(L10n.string(.pdfSearchPrompt), text: $model.searchQuery)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit { model.search() }
                .accessibilityIdentifier("pdf.searchField")
            if model.matchIndex != nil || !model.searchQuery.isEmpty {
                Group {
                    if let index = model.matchIndex {
                        Text(L10n.format(.pdfMatchPosition, index + 1, model.matches.count))
                    } else if !model.searchQuery.isEmpty && model.matches.isEmpty {
                        Text(L10nKey.pdfNoMatches)
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("pdf.matchLabel")
                Button { model.previousMatch() } label: {
                    Image(systemName: "chevron.up").accessibilityLabel(Text(L10nKey.pdfPreviousMatch))
                }
                .disabled(model.matches.count < 2)
                Button { model.nextMatch() } label: {
                    Image(systemName: "chevron.down").accessibilityLabel(Text(L10nKey.pdfNextMatch))
                }
                .disabled(model.matches.count < 2)
                .accessibilityIdentifier("pdf.nextMatch")
            }
        }
        .padding(.horizontal, TLSpacing.l)
        .padding(.vertical, TLSpacing.s)
    }
}

struct ExtractedTextSheet: View {
    let model: PDFViewerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let text = model.extractedText, !text.isEmpty {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .accessibilityIdentifier("pdf.extractedText")
                } else {
                    TLEmptyState(title: .pdfExtractedText, message: .pdfNoText, symbolName: "text.viewfinder")
                        .padding()
                }
            }
            .navigationTitle(Text(L10nKey.pdfExtractedText))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(L10nKey.commonDone) }
                }
                if let text = model.extractedText, !text.isEmpty {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button { UIPasteboard.general.string = text } label: {
                            TLLabel(.actionCopy, systemImage: "doc.on.doc")
                        }
                        Spacer()
                        ShareLink(item: text) { TLLabel(.actionShare, systemImage: "square.and.arrow.up") }
                        Spacer()
                        Button {
                            Task {
                                await model.saveExtractedText()
                                dismiss()
                            }
                        } label: {
                            TLLabel(.pdfSaveText, systemImage: "tray.and.arrow.down")
                        }
                        .accessibilityIdentifier("pdf.saveText")
                    }
                }
            }
        }
    }
}

/// Decides which of PDFKit's page-change notifications are the user's.
///
/// PDFKit also reports pages it shows on its own: a new view starts on page 1
/// and can report it while it lays out, after the reader already asked for the
/// saved page, and a view that is off screen (another screen pushed on top) can
/// report page 1 when it is resized. Saving those moved the reading position,
/// so a reopened PDF sometimes showed page 1. Only moves the user makes, or that
/// match what the reader asked for, count.
struct PDFPageChangeFilter: Equatable {
    enum Decision: Equatable {
        /// The user moved: save this page.
        case report(Int)
        /// Nothing to do.
        case ignore
        /// PDFKit moved on its own before showing the requested page: show it again.
        case restore(Int)
    }

    /// The page the reader asked the view to show, until the view shows it.
    private(set) var pending: Int?

    mutating func requested(_ page: Int) { pending = page }

    /// The view is on the requested page.
    mutating func settled() { pending = nil }

    mutating func pageChanged(to index: Int, isOnScreen: Bool, isUserScrolling: Bool) -> Decision {
        guard isOnScreen else { return .ignore }
        if isUserScrolling {
            pending = nil
            return .report(index)
        }
        guard let pending else { return .report(index) }
        if index == pending {
            self.pending = nil
            return .ignore
        }
        return .restore(pending)
    }
}

/// A PDF view that says when it comes back on screen.
final class ReaderPDFView: PDFView {
    var onWindowChange: (@MainActor () -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }

    /// True while the user drags or flings the pages.
    var isUserScrolling: Bool {
        // The scroll view that holds the pages sits between the document view and this view.
        var ancestor = documentView?.superview
        while let view = ancestor, view !== self {
            if let scrollView = view as? UIScrollView,
               scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
                return true
            }
            ancestor = view.superview
        }
        return false
    }
}

/// PDFKit's view, kept in sync with the model's page and current search match.
struct PDFKitView: UIViewRepresentable {
    let pdf: PDFDocument
    let page: Int
    let highlight: PDFSelection?
    let onPageChange: @MainActor (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPageChange: onPageChange) }

    func makeUIView(context: Context) -> PDFView {
        let view = ReaderPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.usePageViewController(false)
        view.document = pdf
        context.coordinator.observe(view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.onPageChange = onPageChange
        if view.document !== pdf { view.document = pdf }
        context.coordinator.show(page: page, in: view)
        if view.highlightedSelections != highlight.map({ [$0] }) {
            highlight?.color = .systemYellow
            view.highlightedSelections = highlight.map { [$0] }
            if let highlight { view.go(to: highlight) }
        }
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
        (view as? ReaderPDFView)?.onWindowChange = nil
    }

    @MainActor
    final class Coordinator {
        var onPageChange: @MainActor (Int) -> Void
        private var observer: NSObjectProtocol?
        private var filter = PDFPageChangeFilter()
        /// The page the reader wants shown.
        private var target = 0

        init(onPageChange: @escaping @MainActor (Int) -> Void) {
            self.onPageChange = onPageChange
        }

        /// Shows the reader's page, and remembers it until the view gets there.
        func show(page: Int, in view: PDFView) {
            target = page
            guard let document = view.document, let wanted = document.page(at: page) else { return }
            if view.currentPage == wanted {
                filter.settled()
            } else {
                filter.requested(page)
                view.go(to: wanted)
            }
        }

        func observe(_ view: ReaderPDFView) {
            view.onWindowChange = { [weak self, weak view] in
                // Back on screen: show the reader's page, whatever PDFKit did while away.
                guard let self, let view, view.window != nil else { return }
                self.show(page: self.target, in: view)
            }
            observer = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let self, let view, let page = view.currentPage, let document = view.document else { return }
                    let index = document.index(for: page)
                    guard index != NSNotFound else { return }
                    switch self.filter.pageChanged(to: index, isOnScreen: view.window != nil, isUserScrolling: view.isUserScrolling) {
                    case .report(let index):
                        self.target = index
                        self.onPageChange(index)
                    case .ignore:
                        break
                    case .restore(let index):
                        if let wanted = document.page(at: index) { view.go(to: wanted) }
                    }
                }
            }
        }

        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}

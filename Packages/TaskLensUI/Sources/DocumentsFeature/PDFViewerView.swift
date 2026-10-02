import PDFKit
import SwiftUI
import TLDesignSystem
import TLDomain
import TLLocalization

public struct PDFViewerView: View {
    @State private var model: PDFViewerModel
    @State private var isSearching = false
    @State private var showsText = false
    @State private var isGoingToPage = false
    @State private var pageInput = ""

    public init(model: PDFViewerModel) {
        _model = State(initialValue: model)
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
            ToolbarItemGroup(placement: .bottomBar) {
                Button { model.previousPage() } label: {
                    TLLabel(.pdfPreviousPage, systemImage: "chevron.backward")
                }
                .disabled(!model.canGoBack)
                .accessibilityIdentifier("pdf.previousPage")
                Spacer()
                Text(L10n.format(.pdfPage, model.currentPage + 1, model.pageCount))
                    .font(.footnote.monospacedDigit())
                    .accessibilityIdentifier("pdf.pageLabel")
                Spacer()
                Button { model.nextPage() } label: {
                    TLLabel(.pdfNextPage, systemImage: "chevron.forward")
                }
                .disabled(!model.canGoForward)
                .accessibilityIdentifier("pdf.nextPage")
            }
        }
        .toolbar(.visible, for: .bottomBar)
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

/// PDFKit's view, kept in sync with the model's page and current search match.
struct PDFKitView: UIViewRepresentable {
    let pdf: PDFDocument
    let page: Int
    let highlight: PDFSelection?
    let onPageChange: @MainActor (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPageChange: onPageChange) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
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
        if let target = pdf.page(at: page), view.currentPage != target {
            view.go(to: target)
        }
        if view.highlightedSelections != highlight.map({ [$0] }) {
            highlight?.color = .systemYellow
            view.highlightedSelections = highlight.map { [$0] }
            if let highlight { view.go(to: highlight) }
        }
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator {
        var onPageChange: @MainActor (Int) -> Void
        private var observer: NSObjectProtocol?

        init(onPageChange: @escaping @MainActor (Int) -> Void) {
            self.onPageChange = onPageChange
        }

        func observe(_ view: PDFView) {
            observer = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let view, let page = view.currentPage, let document = view.document else { return }
                    let index = document.index(for: page)
                    if index != NSNotFound { self?.onPageChange(index) }
                }
            }
        }

        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}

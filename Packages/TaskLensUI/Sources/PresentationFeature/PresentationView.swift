import PDFKit
import SwiftUI
import TLCoreServices
import TLDesignSystem
import TLDomain
import TLLocalization
import TLNavigation
import UniformTypeIdentifiers

/// Shows one slide at a time with Previous, Next and a "Slide 12 / 48" counter.
///
/// The slide fills the screen. Tapping it hides or shows the controls, the
/// navigation bar and the tab bar; nothing hides on its own. Auto play moves
/// slides on the chosen interval; the controls' visibility has no timer.
public struct PresentationView: View {
    @State private var model: PresentationModel
    /// Import PDF on the PowerPoint failure screen (A9.5.3); nil for other sources.
    @State private var pdfFallback: PDFFallbackImport?
    @State private var showsControls = true
    @State private var isGoingToSlide = false
    @State private var slideInput = ""
    @State private var isChoosingInterval = false
    @State private var intervalInput = ""
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router: AppRouter?

    /// `pdfFallback` is what the model's Import PDF callback starts; this
    /// screen shows its picker and opens the PDF it imports.
    public init(model: PresentationModel, pdfFallback: PDFFallbackImport? = nil) {
        _model = State(initialValue: model)
        _pdfFallback = State(initialValue: pdfFallback)
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
            if showsControls && model.hasSlides {
                Divider()
                controlBar
            }
        }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.hasSlides { intervalMenu }
            }
        }
        .toolbar(showsControls ? .visible : .hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(!showsControls)
        .persistentSystemOverlays(showsControls ? .automatic : .hidden)
        .alert(Text(L10nKey.presentationGoToSlide), isPresented: $isGoingToSlide) {
            TextField(String(model.slideNumber), text: $slideInput)
                .keyboardType(.numberPad)
                .accessibilityIdentifier("presentation.goToSlideField")
            Button {
                if let number = Int(slideInput) { model.goToSlide(number: number) }
                slideInput = ""
            } label: { Text(L10nKey.commonOk) }
            Button(role: .cancel) { slideInput = "" } label: { Text(L10nKey.commonCancel) }
        }
        .alert(Text(L10nKey.presentationAutoPlayInterval), isPresented: $isChoosingInterval) {
            TextField(String(model.autoPlayInterval), text: $intervalInput)
                .keyboardType(.numberPad)
            Button {
                if let seconds = Self.number(from: intervalInput) { model.setAutoPlayInterval(seconds) }
                intervalInput = ""
            } label: { Text(L10nKey.commonOk) }
            Button(role: .cancel) { intervalInput = "" } label: { Text(L10nKey.commonCancel) }
        } message: {
            Text(L10nKey.presentationAutoPlayCustomMessage)
        }
        .modifier(PDFFallbackPresenter(fallback: pdfFallback) { pdf in
            // The PDF takes this screen's place, so Back goes where it would have gone from here.
            router?.replaceTop(with: .presentation(.pdf(pdf)))
        })
        .task { await model.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.didEnterBackground() }
        }
        // Keep the screen awake only while slides advance on their own.
        .onChange(of: model.isAutoPlaying) { _, playing in
            UIApplication.shared.isIdleTimerDisabled = playing
        }
        .onDisappear {
            model.didLeave()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            ProgressView { Text(L10nKey.presentationLoading) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("presentation.loading")
        case .error(let failure):
            if let content = model.failureContent {
                PresentationFailureView(content) { action in
                    switch action {
                    case .retry: Task { await model.retry() }
                    case .importPDF: model.importPDF()
                    case .cancel: dismiss()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("presentation.error")
            } else if model.wasCancelled {
                // Leaving is not a failure: no message, just back.
                Color.clear.onAppear { dismiss() }
            } else {
                failureView(failure)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("presentation.error")
            }
        case .ready, .playing, .paused, .completed:
            slide
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showsControls.toggle() } }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(L10n.format(.presentationCounterSpoken, model.slideNumber, model.slideCount)))
                .accessibilityValue(Text(verbatim: model.currentSlideDescription))
                .accessibilityAddTraits(.isImage)
                .accessibilityAction(named: Text(L10nKey.presentationToggleControls)) { showsControls.toggle() }
                .accessibilityIdentifier("presentation.slide")
        }
    }

    @ViewBuilder
    private var slide: some View {
        switch model.currentSlide?.source {
        case .pdfPage(_, let pageIndex):
            if let pdf = model.pdf, pageIndex < pdf.pageCount {
                PDFSlideView(pdf: pdf, pageIndex: pageIndex)
            } else {
                slideFailed
            }
        case .image, .renderedImage:
            if let source = model.currentSlide?.source {
                ImageSlideView(model: model, source: source)
            }
        case nil:
            slideFailed
        }
    }

    private var slideFailed: some View {
        Label { Text(L10nKey.presentationSlideFailed) } icon: { Image(systemName: "exclamationmark.triangle") }
            .foregroundStyle(.white)
            .padding()
            .accessibilityIdentifier("presentation.slideFailed")
    }

    @ViewBuilder
    private func failureView(_ failure: PresentationFailure) -> some View {
        switch failure {
        case .empty:
            TLEmptyState(title: .presentationEmptyTitle, message: .presentationEmptyMessage, symbolName: "rectangle.on.rectangle.slash")
        case .unsupportedSource:
            TLEmptyState(title: .presentationUnsupportedTitle, message: .presentationUnsupportedMessage, symbolName: "doc.badge.ellipsis")
        case .unreadable:
            TLEmptyState(title: .presentationUnreadableTitle, message: .presentationUnreadableMessage, symbolName: "exclamationmark.triangle")
        }
    }

    // MARK: Controls

    private var controlBar: some View {
        HStack {
            Button { model.previous() } label: {
                Image(systemName: "chevron.backward")
                    .accessibilityLabel(Text(L10nKey.presentationPrevious))
            }
            .disabled(!model.canGoBack)
            .accessibilityIdentifier("presentation.previous")
            Spacer()
            autoPlayButton
            if model.isAutoPlayActive {
                Button { model.stopAutoPlay() } label: {
                    Image(systemName: "stop.fill")
                        .accessibilityLabel(Text(L10nKey.presentationAutoPlayStop))
                }
                .accessibilityIdentifier("presentation.autoPlayStop")
            }
            Spacer()
            Button { isGoingToSlide = true } label: {
                Text(L10n.format(.presentationCounter, model.slideNumber, model.slideCount))
                    .font(.body.monospacedDigit())
            }
            .accessibilityLabel(Text(L10n.format(.presentationCounterSpoken, model.slideNumber, model.slideCount)))
            .accessibilityHint(Text(L10nKey.presentationGoToSlide))
            .accessibilityIdentifier("presentation.counter")
            Spacer()
            Button { model.next() } label: {
                Image(systemName: "chevron.forward")
                    .accessibilityLabel(Text(L10nKey.presentationNext))
            }
            .disabled(!model.canGoForward)
            .accessibilityIdentifier("presentation.next")
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
        .padding(.horizontal, TLSpacing.l)
        .padding(.vertical, TLSpacing.m)
        .background(.bar)
    }

    /// A whole number typed with Western or Arabic-Indic digits.
    static func number(from input: String) -> Int? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if let value = Int(trimmed) { return value }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ar")
        formatter.allowsFloats = false
        return formatter.number(from: trimmed)?.intValue
    }

    private var autoPlayButton: some View {
        Button { model.toggleAutoPlay() } label: {
            switch model.autoPlayButton {
            case .start:
                Image(systemName: "play.fill").accessibilityLabel(Text(L10nKey.presentationAutoPlayStart))
            case .pause:
                Image(systemName: "pause.fill").accessibilityLabel(Text(L10nKey.presentationAutoPlayPause))
            case .resume:
                Image(systemName: "play.fill").accessibilityLabel(Text(L10nKey.presentationAutoPlayResume))
            }
        }
        .accessibilityIdentifier("presentation.autoPlay")
    }

    private var intervalMenu: some View {
        Menu {
            ForEach(PresentationAutoPlayer.presetIntervals, id: \.self) { seconds in
                Button { model.setAutoPlayInterval(seconds) } label: {
                    if seconds == model.autoPlayInterval {
                        Label { Text(L10n.format(.presentationAutoPlaySeconds, seconds)) } icon: { Image(systemName: "checkmark") }
                    } else {
                        Text(L10n.format(.presentationAutoPlaySeconds, seconds))
                    }
                }
                .accessibilityIdentifier("presentation.interval.\(seconds)")
            }
            Button { isChoosingInterval = true } label: {
                if PresentationAutoPlayer.presetIntervals.contains(model.autoPlayInterval) {
                    Text(L10nKey.presentationAutoPlayCustom)
                } else {
                    Label { Text(L10nKey.presentationAutoPlayCustom) } icon: { Image(systemName: "checkmark") }
                }
            }
            .accessibilityIdentifier("presentation.interval.custom")
        } label: {
            Label { Text(L10nKey.presentationAutoPlayInterval) } icon: { Image(systemName: "timer") }
        }
        .accessibilityValue(Text(L10n.format(.presentationAutoPlaySeconds, model.autoPlayInterval)))
        .accessibilityIdentifier("presentation.interval")
    }
}

/// The file picker, progress and error alert of Import PDF, and opening the
/// imported PDF. Does nothing without a fallback.
private struct PDFFallbackPresenter: ViewModifier {
    let fallback: PDFFallbackImport?
    let open: @MainActor (DocumentID) -> Void

    func body(content: Content) -> some View {
        if let model = fallback {
            @Bindable var fallback = model
            content
                .fileImporter(isPresented: $fallback.isChoosing, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
                    switch result {
                    case .success(let urls): Task { await model.picked(urls.first) }
                    case .failure: model.pickerFailed()
                    }
                }
                .overlay {
                    if model.isImporting {
                        ProgressView().accessibilityIdentifier("presentation.importingPDF")
                    }
                }
                .errorAlert(message: $fallback.errorMessage)
                .onChange(of: model.importedPDF) { _, pdf in
                    if let pdf { open(pdf) }
                }
        } else {
            content
        }
    }
}

/// One PDF page, fitted to the space. PDFKit draws only this page.
private struct PDFSlideView: UIViewRepresentable {
    let pdf: PDFDocument
    let pageIndex: Int

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.autoScales = true
        view.backgroundColor = .black
        // Pages change only through the presentation controls.
        view.isUserInteractionEnabled = false
        view.document = pdf
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== pdf { view.document = pdf }
        if let page = pdf.page(at: pageIndex), view.currentPage != page {
            view.go(to: page)
        }
        view.scaleFactor = view.scaleFactorForSizeToFit
    }
}

/// One image, aspect-fit, decoded for the screen size when it appears: an
/// imported image or a rendered PowerPoint slide.
private struct ImageSlideView: View {
    let model: PresentationModel
    let source: PresentationSlideSource
    @State private var image: CGImage?
    @State private var loadedID: PresentationSlideSource?
    @State private var failed = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image, loadedID == source {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .scaledToFit()
                } else if failed {
                    Label { Text(L10nKey.presentationSlideFailed) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .foregroundStyle(.white)
                        .padding()
                        .accessibilityIdentifier("presentation.slideFailed")
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .task(id: source) {
                failed = false
                let longestSide = max(geometry.size.width, geometry.size.height) * displayScale
                let decoded = await model.image(for: source, maxPixelSize: longestSide)
                guard !Task.isCancelled else { return }
                image = decoded
                loadedID = source
                failed = decoded == nil
            }
        }
    }
}

import SwiftUI
import TLDesignSystem
import TLDomain
import TLLocalization

public struct ImageViewerView: View {
    @State private var model: ImageViewerModel
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @State private var showsOCRNotice = false

    public init(model: ImageViewerModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        GeometryReader { proxy in
            Group {
                if let image = model.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(zoom)
                        .offset(offset)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .gesture(magnify.simultaneously(with: drag))
                        .onTapGesture(count: 2) { toggleZoom() }
                        .accessibilityLabel(Text(model.document?.title ?? ""))
                        .accessibilityAddTraits(.isImage)
                        .accessibilityIdentifier("image.view")
                } else if model.failedToOpen {
                    TLEmptyState(title: .documentsOpenFailed, message: .documentsEmptyMessage, symbolName: "exclamationmark.triangle")
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    ProgressView().frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
        .clipped()
        .background(Color(.systemBackground))
        .navigationTitle(model.document?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                if let url = model.fileURL {
                    ShareLink(item: url) { TLLabel(.actionShare, systemImage: "square.and.arrow.up") }
                }
                Spacer()
                // Entry point only: on-device text recognition arrives in a later phase.
                Button { showsOCRNotice = true } label: {
                    TLLabel(.imageRecognizeText, systemImage: "text.viewfinder")
                }
                .accessibilityIdentifier("image.recognizeText")
                Spacer()
                Button { Task { await model.save() } } label: {
                    TLLabel(.commonSaveToSession, systemImage: "tray.and.arrow.down")
                }
                .disabled(model.document == nil)
                .accessibilityIdentifier("image.save")
            }
            ToolbarItem(placement: .primaryAction) {
                if zoom != 1 {
                    Button { resetZoom() } label: {
                        TLLabel(.imageResetZoom, systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                }
            }
        }
        .toolbar(.visible, for: .bottomBar)
        .alert(Text(L10nKey.imageRecognizeText), isPresented: $showsOCRNotice) {
            Button(role: .cancel) {} label: { Text(L10nKey.commonOk) }
        } message: {
            Text(L10nKey.imageOcrLater)
        }
        .sensoryFeedback(.success, trigger: model.savedItemCount)
        .task { await model.load() }
        .errorAlert(message: $model.errorMessage)
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in zoom = min(max(committedZoom * value.magnification, 1), 6) }
            .onEnded { _ in
                committedZoom = zoom
                if zoom == 1 { resetZoom() }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1 else { return }
                offset = CGSize(
                    width: committedOffset.width + value.translation.width,
                    height: committedOffset.height + value.translation.height
                )
            }
            .onEnded { _ in committedOffset = offset }
    }

    private func toggleZoom() {
        if zoom > 1 { resetZoom() } else {
            withAnimation(.snappy) { zoom = 2.5; committedZoom = 2.5 }
        }
    }

    private func resetZoom() {
        withAnimation(.snappy) {
            zoom = 1
            committedZoom = 1
            offset = .zero
            committedOffset = .zero
        }
    }
}

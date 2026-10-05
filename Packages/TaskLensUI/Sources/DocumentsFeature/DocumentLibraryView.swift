import PhotosUI
import SwiftUI
import TLCoreServices
import TLDesignSystem
import TLDomain
import TLLocalization
import TLNavigation
import UniformTypeIdentifiers

public struct DocumentLibraryView: View {
    @State private var model: DocumentLibraryModel
    @State private var isPickingFiles = false
    @State private var isPickingPhotos = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var pendingDeletion: Document?
    @Environment(AppRouter.self) private var router

    public init(model: DocumentLibraryModel) {
        _model = State(initialValue: model)
    }

    private var imageIDs: [DocumentID] {
        model.documents.filter { $0.kind == .image }.map(\.id)
    }

    public var body: some View {
        List {
            if model.hasLoaded && model.documents.isEmpty {
                TLEmptyState(title: .documentsEmptyTitle, message: .documentsEmptyMessage, symbolName: "doc.on.doc")
                    .listRowBackground(Color.clear)
            }
            ForEach(model.documents) { document in
                Button { router.push(.viewer(for: document)) } label: {
                    DocumentRow(document: document)
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("documentRow.\(document.title)")
                .swipeActions {
                    Button(role: .destructive) { pendingDeletion = document } label: {
                        TLLabel(.commonDelete, systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(Text(L10nKey.workspaceToolDocuments))
        .toolbar {
            if !imageIDs.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    // The images in the order the list shows them.
                    Button { router.push(.presentation(.images(imageIDs))) } label: {
                        TLLabel(.presentationPresentImages, systemImage: "play.rectangle")
                    }
                    .accessibilityIdentifier("documents.presentImages")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { isPickingFiles = true } label: {
                        TLLabel(.documentsImportFiles, systemImage: "folder")
                    }
                    Button { isPickingPhotos = true } label: {
                        TLLabel(.documentsImportPhotos, systemImage: "photo.on.rectangle")
                    }
                } label: {
                    TLLabel(.documentsImport, systemImage: "plus")
                }
                .accessibilityIdentifier("documents.import")
            }
        }
        .overlay {
            if model.isImporting { ProgressView() }
        }
        .fileImporter(
            isPresented: $isPickingFiles,
            allowedContentTypes: DocumentService.importableTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await model.importFiles(urls) }
            case .failure:
                model.errorMessage = L10n.string(.documentsOpenFailed)
            }
        }
        // The photo picker runs out of process: no photo library permission is needed.
        .photosPicker(isPresented: $isPickingPhotos, selection: $photoSelection, matching: .images)
        .onChange(of: photoSelection) { _, item in
            guard let item else { return }
            photoSelection = nil
            Task { await importPhoto(item) }
        }
        .alert(
            Text(L10nKey.documentsDeleteTitle),
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { document in
            Button(role: .destructive) { Task { await model.delete(document.id) } } label: {
                Text(L10nKey.commonDelete)
            }
            Button(role: .cancel) {} label: { Text(L10nKey.commonCancel) }
        } message: { _ in
            Text(L10nKey.documentsDeleteMessage)
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .errorAlert(message: $model.errorMessage)
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                model.errorMessage = L10n.string(.documentsOpenFailed)
                return
            }
            let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .jpeg
            let name = L10n.string(.documentsPhotoName) + "." + (type.preferredFilenameExtension ?? "jpg")
            await model.importData(data, filename: name, contentType: type)
        } catch {
            model.errorMessage = L10n.string(.documentsOpenFailed)
        }
    }
}

struct DocumentRow: View {
    let document: Document

    var body: some View {
        HStack(spacing: TLSpacing.m) {
            Image(systemName: symbolName)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: TLSpacing.xxs) {
                Text(document.title).font(.headline).lineLimit(2)
                HStack(spacing: TLSpacing.xs) {
                    if document.kind == .powerpoint {
                        Text(L10nKey.documentsKindPowerpoint)
                    } else {
                        Text(L10nKey.itemType(ContextContent.file(document.file).itemType))
                    }
                    if let bytes = document.file.byteCount {
                        Text(bytes, format: .byteCount(style: .file))
                    }
                    if let pages = document.pageCount, document.kind == .pdf {
                        Text(verbatim: "· \(pages)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, TLSpacing.xxs)
        .accessibilityElement(children: .combine)
    }

    private var symbolName: String {
        switch document.kind {
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .text: "doc.plaintext"
        case .document: "doc"
        case .powerpoint: "rectangle.on.rectangle"
        }
    }
}

import AVFoundation
import PhotosUI
import SwiftUI
import TLActionsUI
import UIKit
import TLCoreServices
import TLDesignSystem
import TLDomain
import TLLocalization
import UniformTypeIdentifiers

/// Photos, Camera and Files buttons. Every read starts from the user's pick.
struct ImageLensInputSection: View {
    let model: ImageLensModel
    @State private var photoItem: PhotosPickerItem?
    @State private var isImportingFile = false
    @State private var isCameraDenied = false
    @State private var isExplainingCamera = false
    @Environment(\.openURL) private var openURL
    @State private var isShowingCamera = false

    var body: some View {
        Section {
            HStack(spacing: TLSpacing.s) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    TLLabel(.lensImagePhotos, systemImage: "photo.on.rectangle")
                }
                .accessibilityIdentifier("lens.image.photos")
                if CameraPicker.isAvailable {
                    Button {
                        // A denied camera would open a blank screen: explain instead.
                        switch AVCaptureDevice.authorizationStatus(for: .video) {
                        case .denied, .restricted: isCameraDenied = true
                        // Say why before iOS asks for the first time.
                        case .notDetermined: isExplainingCamera = true
                        default: isShowingCamera = true
                        }
                    } label: {
                        TLLabel(.lensImageCamera, systemImage: "camera")
                    }
                    .accessibilityIdentifier("lens.image.camera")
                }
                Button { isImportingFile = true } label: {
                    TLLabel(.lensImageFiles, systemImage: "folder")
                }
                .accessibilityIdentifier("lens.image.files")
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleAndIcon)
            .font(.callout)
        } header: {
            Text(L10nKey.lensImageSection)
        } footer: {
            Text(L10nKey.lensImagePrivacy)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await model.read(data: data, source: .photoLibrary)
                } else {
                    model.failedToLoad(source: .photoLibrary)
                }
            }
        }
        .fileImporter(isPresented: $isImportingFile, allowedContentTypes: [.image, .pdf]) { result in
            switch result {
            case .success(let url):
                Task { await model.read(fileAt: url, source: .fileImport) }
            case .failure:
                model.failedToLoad(source: .fileImport)
            }
        }
        .alert(Text(L10nKey.lensCameraExplainTitle), isPresented: $isExplainingCamera) {
            Button {
                isShowingCamera = true
            } label: {
                Text(L10nKey.commonContinue)
            }
            .accessibilityIdentifier("lens.camera.continue")
            Button(role: .cancel) {} label: { Text(L10nKey.lensCameraNotNow) }
        } message: {
            Text(L10nKey.lensCameraExplainMessage)
        }
        .alert(Text(L10nKey.lensCameraDeniedTitle), isPresented: $isCameraDenied) {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                Text(L10nKey.settingsOpenSettings)
            }
            Button(role: .cancel) {} label: { Text(L10nKey.commonCancel) }
        } message: {
            Text(L10nKey.lensCameraDeniedMessage)
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraPicker { image in
                isShowingCamera = false
                guard let image else { return }
                Task { await model.read(image, source: .camera) }
            }
            .ignoresSafeArea()
        }
    }
}

/// The image, "What I found", and the recommended actions for the chosen finding.
struct ImageLensResultSections: View {
    @Bindable var model: ImageLensModel
    let feedback: ActionFeedback
    let handlers: (LensFinding) -> ActionHandlers

    var body: some View {
        Section {
            if let preview = model.preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 180)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
            switch model.phase {
            case .reading:
                HStack {
                    ProgressView()
                    Text(L10nKey.lensImageReading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("lens.image.reading")
            case .failed:
                Text(L10nKey.lensImageFailed)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("lens.image.failed")
            case .done where model.findings.isEmpty:
                Text(L10nKey.lensImageNothing)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("lens.image.nothing")
            default:
                EmptyView()
            }
            Button(role: .destructive) { model.clear() } label: {
                TLLabel(.lensImageClear, systemImage: "xmark.circle")
            }
            .accessibilityIdentifier("lens.image.clear")
        }

        if !model.findings.isEmpty {
            Section {
                ForEach(model.findings) { finding in
                    FindingRow(finding: finding, isSelected: finding.id == model.selectedID) {
                        model.selectedID = finding.id
                    }
                }
                if let structure = model.report?.structure, let title = structure.title {
                    Text(verbatim: L10n.format(.lensImageDocumentTitle, title))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(verbatim: L10n.format(.lensImageParagraphs, structure.paragraphs.count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(L10nKey.lensImageFound)
            }
        }

        SelectedFindingSection(model: model, feedback: feedback, handlers: handlers)
    }
}

/// Recommended actions for the chosen finding, or, for a possible match, the
/// field to check it first. Shared by image and Screen Lens results.
struct SelectedFindingSection: View {
    @Bindable var model: ImageLensModel
    let feedback: ActionFeedback
    let handlers: (LensFinding) -> ActionHandlers
    @State private var correction = ""

    var body: some View {
        if let finding = model.selected {
            if let analysis = model.analysis(for: finding) {
                ActionCard(
                    analysis: analysis,
                    content: model.content(for: finding),
                    feedback: feedback,
                    isSaved: model.savedIDs.contains(finding.id),
                    handlers: handlers(finding)
                )
            } else {
                // A possible match: nothing happens until the user checks it.
                Section {
                    Text(L10nKey.lensImagePossibleHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField(L10n.string(.lensInput), text: $correction, axis: .vertical)
                        .accessibilityIdentifier("lens.image.correction")
                    Button { model.confirm(finding, text: correction) } label: {
                        TLLabel(.lensImageConfirm, systemImage: "checkmark.circle")
                    }
                    .disabled(correction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("lens.image.confirm")
                } header: {
                    Text(L10nKey.lensImagePossible)
                }
                .onAppear { correction = finding.text }
                .onChange(of: model.selectedID) { _, _ in correction = model.selected?.text ?? "" }
            }
        }
    }
}

/// One finding: what it is, its value, and whether it is only a possible match.
struct FindingRow: View {
    let finding: LensFinding
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: TLSpacing.s) {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: finding.text)
                        .lineLimit(finding.source == .allText ? 3 : 2)
                        .foregroundStyle(.primary)
                    if finding.certainty == .possible {
                        Text(L10nKey.lensImagePossible)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(L10nKey.lensImageSelect))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("lens.finding")
    }

    private var kind: L10nKey {
        switch finding.source {
        case .allText: .lensImageAllText
        case .code(.qr): .lensImageQr
        case .code(.barcode): .lensImageBarcode
        case .text: finding.entityType.map(L10nKey.entityType) ?? .categoryUnknown
        }
    }

    private var symbol: String {
        switch finding.source {
        case .allText: return "text.alignleft"
        case .code(.qr): return "qrcode"
        case .code(.barcode): return "barcode"
        case .text:
            switch finding.entityType {
            case .url: return "link"
            case .phoneNumber: return "phone"
            case .email: return "envelope"
            case .currencyAmount: return "banknote"
            case .date: return "calendar"
            case .address: return "map"
            case .code, .json: return "chevron.left.forwardslash.chevron.right"
            default: return "number"
            }
        }
    }
}

/// The system camera, for one photo. Only offered on devices with a camera.
struct CameraPicker: UIViewControllerRepresentable {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    let completion: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (UIImage?) -> Void

        init(completion: @escaping (UIImage?) -> Void) {
            self.completion = completion
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            completion(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            completion(nil)
        }
    }
}

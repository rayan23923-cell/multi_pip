import SwiftUI
import TLActionsUI
import TLCoreServices
import TLDesignSystem
import TLDomain
import TLLocalization

/// Share sheet UI: what was shared, what TaskLens found in it, suggested
/// actions, and Save to Session.
public struct ShareView: View {
    @State private var model: ShareModel
    @State private var feedback = ActionFeedback()

    public init(model: ShareModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text(L10nKey.shareTitle))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { model.cancel() } label: { Text(L10nKey.commonCancel) }
                            .disabled(isFinishing)
                            .accessibilityIdentifier("share.cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await model.save() }
                        } label: {
                            Text(L10nKey.commonSave)
                        }
                        .disabled(!model.canSave)
                        .accessibilityIdentifier("share.save")
                    }
                }
                .actionFeedback(feedback)
                .errorAlert(message: $model.errorMessage)
        }
        .task { model.start() }
    }

    private var isFinishing: Bool {
        switch model.phase {
        case .saving, .saved: true
        case .loading, .ready: false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView {
                Text(L10nKey.shareLoading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("share.loading")
        case .saved:
            ContentUnavailableView {
                Label {
                    Text(L10nKey.commonSaved)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } description: {
                Text(L10nKey.shareSaved)
            }
            .accessibilityIdentifier("share.saved")
        case .ready, .saving:
            list
        }
    }

    private var list: some View {
        List {
            if model.supportedCount == 0 {
                Section {
                    Label {
                        Text(L10nKey.shareNothingSupported)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    .accessibilityIdentifier("share.nothingSupported")
                }
            } else {
                Section {
                    Picker(selection: $model.selectedSessionID) {
                        Text(L10nKey.shareInbox).tag(SessionID?.none)
                        ForEach(model.sessions) { session in
                            Text(verbatim: model.sessionTitle(session)).tag(SessionID?.some(session.id))
                        }
                    } label: {
                        Text(L10nKey.shareDestination)
                    }
                    .accessibilityIdentifier("share.destination")
                    Button {
                        Task { await model.save() }
                    } label: {
                        TLLabel(.shareSave, systemImage: "tray.and.arrow.down")
                    }
                    .disabled(!model.canSave)
                    .accessibilityIdentifier("share.saveToSession")
                }
            }

            ForEach(Array(model.previews.enumerated()), id: \.element.id) { index, preview in
                item(preview, index: index)
            }
        }
    }

    @ViewBuilder
    private func item(_ preview: ShareService.Preview, index: Int) -> some View {
        if case .unsupported(let reason, _) = preview.attachment.payload {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: TLSpacing.xxs) {
                        Text(L10nKey.shareUnsupported)
                        Text(Self.reasonKey(reason))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "nosign")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("share.item.\(index).unsupported")
            }
        } else {
            Section {
                DetectedTypeRow(preview.analysis.category)
                    .accessibilityIdentifier("share.item.\(index).type")
                DetectedValueRow(preview.analysis)
                previewRow(preview)
            }
            // Saving is the sheet's main button; sharing from inside a share sheet is not offered.
            ActionCard(
                analysis: preview.analysis,
                content: preview.content,
                feedback: feedback,
                capabilities: .shareExtension,
                hiding: [.saveToSession, .share]
            )
            EntitiesSection(preview.analysis.entities)
        }
    }

    @ViewBuilder
    private func previewRow(_ preview: ShareService.Preview) -> some View {
        switch preview.attachment.payload {
        case .file(_, _, let filename, let byteCount):
            HStack(spacing: TLSpacing.m) {
                if let thumbnail = model.thumbnails[preview.id] {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: TLRadius.small))
                } else {
                    Image(systemName: preview.analysis.category.symbolName)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 56, height: 56)
                }
                VStack(alignment: .leading, spacing: TLSpacing.xxs) {
                    Text(verbatim: filename)
                        .lineLimit(2)
                    Text(Int64(byteCount), format: .byteCount(style: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        default:
            if let content = preview.content {
                ContentPreview(content, lineLimit: 6)
            }
        }
    }

    static func reasonKey(_ reason: SharedAttachment.UnsupportedReason) -> L10nKey {
        switch reason {
        case .type: .shareUnsupportedType
        case .tooLarge: .shareUnsupportedTooLarge
        case .unreadable: .shareUnsupportedUnreadable
        case .tooMany: .shareUnsupportedTooMany
        }
    }
}

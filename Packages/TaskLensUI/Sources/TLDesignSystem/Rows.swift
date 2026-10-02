import SwiftUI
import TLDomain
import TLLocalization

public struct WorkspaceRow: View {
    private let workspace: Workspace

    public init(workspace: Workspace) {
        self.workspace = workspace
    }

    public var body: some View {
        HStack(spacing: TLSpacing.m) {
            WorkspaceIcon(workspace: workspace)
            VStack(alignment: .leading, spacing: TLSpacing.xxs) {
                Text(workspace.name)
                    .font(.body)
                    .lineLimit(2)
                HStack(spacing: TLSpacing.xs) {
                    Text(L10nKey.workspaceKind(workspace.kind))
                    if let opened = workspace.lastOpenedAt {
                        Text(verbatim: "·")
                        Text(opened, format: .relative(presentation: .named))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: TLSpacing.s)
            if workspace.isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel(Text(L10nKey.workspacesFavorites))
            }
        }
        .padding(.vertical, TLSpacing.xxs)
        .accessibilityElement(children: .combine)
    }
}

public struct SessionRow: View {
    private let session: Session
    private let workspaceName: String?

    public init(session: Session, workspaceName: String? = nil) {
        self.session = session
        self.workspaceName = workspaceName
    }

    public var body: some View {
        HStack(spacing: TLSpacing.m) {
            Image(systemName: session.kind.symbolName)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: TLSpacing.xxs) {
                HStack(spacing: TLSpacing.xs) {
                    title
                        .font(.body)
                        .lineLimit(1)
                    if session.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel(Text(L10nKey.sessionFavorites))
                    }
                }
                HStack(spacing: TLSpacing.xs) {
                    Text(L10nKey.sessionKind(session.kind))
                    if let workspaceName {
                        Text(verbatim: "·")
                        Text(workspaceName).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: TLSpacing.s)
            if session.isArchived {
                StatusBadge(.sessionStateArchived, tint: .secondary)
            } else {
                StatusBadge(L10nKey.sessionState(session.state), tint: session.state.tint)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var title: some View {
        if let text = session.title {
            Text(text)
        } else {
            Text(L10nKey.sessionUntitled)
        }
    }
}

public struct ContextItemRow: View {
    private let item: ContextItem

    public init(item: ContextItem) {
        self.item = item
    }

    public var body: some View {
        HStack(alignment: .top, spacing: TLSpacing.m) {
            Image(systemName: item.type.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: TLSpacing.xxs) {
                preview
                    .font(.body)
                    .lineLimit(3)
                HStack(spacing: TLSpacing.xs) {
                    Text(L10nKey.itemType(item.type))
                    Text(verbatim: "·")
                    Text(item.createdAt, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var preview: some View {
        switch item.content {
        case .text(let text):
            Text(text)
        case .url(let url):
            Text(url.absoluteString)
                .foregroundStyle(.tint)
                // Links and numbers stay left-to-right inside Arabic UI.
                .environment(\.layoutDirection, .leftToRight)
        case .file(let reference):
            Text(reference.originalFilename ?? reference.relativePath)
        }
    }
}

/// Text field plus save button used for quick capture.
public struct QuickCaptureBar: View {
    @Binding private var text: String
    private let isSaving: Bool
    private let onSubmit: () -> Void

    public init(text: Binding<String>, isSaving: Bool, onSubmit: @escaping () -> Void) {
        _text = text
        self.isSaving = isSaving
        self.onSubmit = onSubmit
    }

    private var canSubmit: Bool {
        !isSaving && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: TLSpacing.s) {
            TextField(L10n.string(.capturePlaceholder), text: $text, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canSubmit { onSubmit() } }
                .accessibilityIdentifier("quickCapture.field")
            Button {
                onSubmit()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .accessibilityLabel(Text(L10nKey.commonSave))
            }
            .disabled(!canSubmit)
            .accessibilityIdentifier("quickCapture.save")
        }
    }
}

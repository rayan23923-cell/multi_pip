import SwiftUI
import TLDomain
import TLLocalization

/// Create/edit form for a workspace. Owns no persistence: the caller saves.
public struct WorkspaceEditor: View {
    public enum Mode: Sendable {
        case create
        case edit
    }

    @Environment(\.dismiss) private var dismiss
    @State private var draft: WorkspaceDraft
    @State private var isSaving = false
    private let mode: Mode
    private let onSave: (WorkspaceDraft) async -> Bool

    public init(mode: Mode, draft: WorkspaceDraft = WorkspaceDraft(), onSave: @escaping (WorkspaceDraft) async -> Bool) {
        self.mode = mode
        _draft = State(initialValue: draft)
        self.onSave = onSave
    }

    private var canSave: Bool {
        !isSaving && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.string(.workspacesName), text: $draft.name)
                        .font(.title3)
                        .submitLabel(.done)
                        .accessibilityIdentifier("workspaceEditor.name")
                    Picker(selection: kindBinding) {
                        ForEach(WorkspaceKind.allKnown, id: \.self) { kind in
                            TLLabel(L10nKey.workspaceKind(kind), systemImage: kind.defaultSymbolName)
                                .tag(kind)
                        }
                    } label: {
                        Text(L10nKey.workspaceEditorKind)
                    }
                    .accessibilityIdentifier("workspaceEditor.kind")
                }

                Section {
                    iconGrid
                    colorRow
                } header: {
                    Text(L10nKey.workspaceEditorIcon)
                }

                Section {
                    ForEach(WorkspaceTool.allKnown, id: \.self) { tool in
                        Toggle(isOn: toolBinding(tool)) {
                            TLLabel(L10nKey.workspaceTool(tool), systemImage: tool.symbolName)
                        }
                    }
                } header: {
                    Text(L10nKey.workspaceTools)
                }

                Section {
                    Picker(selection: $draft.settings.defaultSessionKind) {
                        ForEach(SessionKind.allKnown, id: \.self) { kind in
                            Text(L10nKey.sessionKind(kind)).tag(kind)
                        }
                    } label: {
                        Text(L10nKey.workspaceEditorDefaultSessionKind)
                    }
                    Toggle(isOn: $draft.settings.resumesLastSession) {
                        Text(L10nKey.workspaceEditorResumesLastSession)
                    }
                } header: {
                    Text(L10nKey.workspaceEditorSettings)
                }
            }
            .navigationTitle(Text(mode == .create ? L10nKey.workspacesCreate : L10nKey.workspaceEditorEditTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(L10nKey.commonCancel) }
                        .accessibilityIdentifier("workspaceEditor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        Text(mode == .create ? L10nKey.commonCreate : L10nKey.commonSave)
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("workspaceEditor.save")
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func save() async {
        isSaving = true
        let saved = await onSave(draft)
        isSaving = false
        if saved { dismiss() }
    }

    private var kindBinding: Binding<WorkspaceKind> {
        Binding(
            get: { draft.kind },
            set: { draft.applyKind($0) }
        )
    }

    private func toolBinding(_ tool: WorkspaceTool) -> Binding<Bool> {
        Binding(
            get: { draft.tools.contains(tool) },
            set: { isOn in
                if isOn {
                    if !draft.tools.contains(tool) { draft.tools.append(tool) }
                } else {
                    draft.tools.removeAll { $0 == tool }
                }
            }
        )
    }

    private var iconGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: TLSpacing.s)], spacing: TLSpacing.s) {
            ForEach(WorkspaceIconCatalog.symbols, id: \.self) { symbol in
                Button {
                    draft.symbolName = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.body)
                        .frame(width: 44, height: 44)
                        .foregroundStyle(symbol == draft.symbolName ? Color.white : Color.primary)
                        .background(
                            symbol == draft.symbolName ? AnyShapeStyle(draft.color.color) : AnyShapeStyle(.fill.tertiary),
                            in: RoundedRectangle(cornerRadius: TLRadius.small, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                // The symbol's own (system-localized) description is read.
                .accessibilityAddTraits(symbol == draft.symbolName ? .isSelected : [])
            }
        }
        .padding(.vertical, TLSpacing.xs)
    }

    private var colorRow: some View {
        HStack(spacing: TLSpacing.m) {
            ForEach(WorkspaceColor.allKnown, id: \.self) { option in
                Button {
                    draft.color = option
                } label: {
                    Circle()
                        .fill(option.color)
                        .frame(width: 28, height: 28)
                        .overlay {
                            if option == draft.color {
                                Image(systemName: "checkmark")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10nKey(rawValue: "workspace.color.\(option.rawValue)") ?? .workspaceColorBlue))
                .accessibilityAddTraits(option == draft.color ? .isSelected : [])
            }
        }
        .padding(.vertical, TLSpacing.xs)
    }
}

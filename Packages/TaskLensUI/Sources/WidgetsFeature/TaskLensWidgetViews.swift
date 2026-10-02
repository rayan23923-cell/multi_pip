import SwiftUI
import TLCoreServices
import TLDesignSystem
import TLDomain
import TLLocalization
import TLNavigation
import WidgetKit

/// What a widget shows at a moment.
public struct TaskLensWidgetEntry: TimelineEntry, Sendable {
    public let date: Date
    public let snapshot: WidgetSnapshot
    /// True for the gallery preview: sample content, never the user's data.
    public let isPlaceholder: Bool

    public init(date: Date, snapshot: WidgetSnapshot, isPlaceholder: Bool = false) {
        self.date = date
        self.snapshot = snapshot
        self.isPlaceholder = isPlaceholder
    }
}

/// Timeline rules, kept apart from WidgetKit so they can be tested.
public enum TaskLensTimeline {
    /// The app reloads widgets when its data changes; this is only a safety refresh.
    public static let refreshInterval: TimeInterval = 30 * 60

    public static func timeline(snapshot: WidgetSnapshot, now: Date) -> Timeline<TaskLensWidgetEntry> {
        Timeline(entries: [TaskLensWidgetEntry(date: now, snapshot: snapshot)], policy: .after(now.addingTimeInterval(refreshInterval)))
    }

    /// Gallery preview with made-up content in the user's language.
    public static func placeholder(now: Date) -> TaskLensWidgetEntry {
        let workspace = WidgetSnapshot.WorkspaceSummary(
            id: WorkspaceID(), name: L10n.string(.workspaceKindResearch), kind: .research,
            symbolName: WorkspaceKind.research.defaultSymbolName, color: WorkspaceKind.research.defaultColor,
            activeSessionCount: 1
        )
        let session = WidgetSnapshot.SessionSummary(
            id: SessionID(), title: nil, kind: .research, state: .active,
            workspaceName: workspace.name, itemCount: 7, lastActivityAt: now.addingTimeInterval(-600)
        )
        let snapshot = WidgetSnapshot(generatedAt: now, featuredWorkspace: workspace, workspaces: [workspace], sessions: [session])
        return TaskLensWidgetEntry(date: now, snapshot: snapshot, isPlaceholder: true)
    }
}

/// Places a widget's quick actions open. Each is a `tasklens://` link.
public enum WidgetDestination: String, CaseIterable, Sendable {
    case lens
    case clipboard
    case notes
    case calculator

    public var url: URL {
        switch self {
        case .lens: DeepLink.lens
        case .clipboard: DeepLink.clipboard
        case .notes: DeepLink.notes
        case .calculator: DeepLink.calculator
        }
    }

    public var title: L10nKey {
        switch self {
        case .lens: .lensTitle
        case .clipboard: .clipboardTitle
        case .notes: .workspaceToolNotes
        case .calculator: .workspaceToolCalculator
        }
    }

    public var symbolName: String {
        switch self {
        case .lens: "viewfinder"
        case .clipboard: "doc.on.clipboard"
        case .notes: "note.text"
        case .calculator: "plus.forwardslash.minus"
        }
    }

    public var tint: Color {
        switch self {
        case .lens: .purple
        case .clipboard: .orange
        case .notes: .yellow
        case .calculator: .gray
        }
    }
}

/// One quick action tile's look. The widget wraps it in a button or link.
public struct WidgetActionTile: View {
    let destination: WidgetDestination

    public init(_ destination: WidgetDestination) {
        self.destination = destination
    }

    public var body: some View {
        VStack(spacing: 2) {
            Image(systemName: destination.symbolName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(destination.tint)
            Text(destination.title)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Small widget: four quick actions. `action` wraps each tile so it can open
/// TaskLens (an App Intent button in the widget, a link elsewhere).
public struct QuickActionsWidgetView<Action: View>: View {
    let action: (WidgetDestination) -> Action

    public init(@ViewBuilder action: @escaping (WidgetDestination) -> Action) {
        self.action = action
    }

    public var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                action(.lens)
                action(.clipboard)
            }
            GridRow {
                action(.notes)
                action(.calculator)
            }
        }
    }
}

/// One recent session in a widget, opening it.
public struct WidgetSessionRow: View {
    let session: WidgetSnapshot.SessionSummary

    public init(_ session: WidgetSnapshot.SessionSummary) {
        self.session = session
    }

    public var body: some View {
        Link(destination: DeepLink.resume(session.id)) {
            HStack(spacing: 8) {
                Image(systemName: session.kind.symbolName)
                    .foregroundStyle(session.state == .active ? Color.green : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    title
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(verbatim: session.workspaceName)
                        Text(verbatim: "·")
                        Text(session.lastActivityAt, style: .relative)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(session.itemCount, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(L10n.format(.widgetItemCount, session.itemCount)))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: Text {
        if let title = session.title, !title.isEmpty { Text(verbatim: title) } else { Text(L10nKey.sessionKind(session.kind)) }
    }
}

/// Medium widget: recent sessions.
public struct RecentSessionsWidgetView: View {
    let snapshot: WidgetSnapshot
    let limit: Int

    public init(snapshot: WidgetSnapshot, limit: Int = 3) {
        self.snapshot = snapshot
        self.limit = limit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(L10nKey.widgetRecentSessions)
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            if snapshot.sessions.isEmpty {
                Spacer()
                Text(L10nKey.widgetNoSessions)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(snapshot.sessions.prefix(limit)) { session in
                    WidgetSessionRow(session)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Large widget: the featured workspace and recent sessions.
public struct WorkspaceWidgetView: View {
    let snapshot: WidgetSnapshot

    public init(snapshot: WidgetSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let workspace = snapshot.featuredWorkspace {
                Link(destination: DeepLink.workspace(workspace.id)) {
                    HStack(spacing: 10) {
                        WorkspaceIcon(symbolName: workspace.symbolName, color: workspace.color, size: 36)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: workspace.name)
                                .font(.headline)
                                .lineLimit(1)
                            Text(L10nKey.workspaceKind(workspace.kind))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if workspace.activeSessionCount > 0 {
                            Text(L10nKey.sessionStateActive)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.green.opacity(0.2), in: Capsule())
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
                Link(destination: DeepLink.workspaces) {
                    Label {
                        Text(L10nKey.widgetNoWorkspaces)
                    } icon: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            Divider()
            RecentSessionsWidgetView(snapshot: snapshot, limit: 4)
        }
    }
}

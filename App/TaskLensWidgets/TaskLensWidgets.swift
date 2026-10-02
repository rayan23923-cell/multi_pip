import SwiftUI
import TLCoreServices
import TLLocalization
import WidgetKit
import WidgetsFeature

@main
struct TaskLensWidgetBundle: WidgetBundle {
    var body: some Widget {
        TaskLensWidget()
    }
}

/// One widget in three sizes:
/// small = quick actions, medium = recent sessions, large = workspace + recent sessions.
/// It reads only the snapshot the app writes to the App Group container; it
/// never opens the app's store and never uses the network.
struct TaskLensWidget: Widget {
    static let kind = "TaskLensWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            TaskLensWidgetView(entry: entry)
        }
        .configurationDisplayName(Text(L10nKey.widgetName))
        .description(Text(L10nKey.widgetDescription))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct SnapshotProvider: TimelineProvider {
    private var store: WidgetSnapshotStore? {
        WidgetSnapshotStore.shared(appGroupIdentifier: Bundle.main.object(forInfoDictionaryKey: "TLAppGroupIdentifier") as? String)
    }

    private func current() -> WidgetSnapshot {
        store?.read() ?? .empty
    }

    func placeholder(in context: Context) -> TaskLensWidgetEntry {
        TaskLensTimeline.placeholder(now: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (TaskLensWidgetEntry) -> Void) {
        let snapshot = current()
        if context.isPreview && snapshot.isEmpty {
            completion(TaskLensTimeline.placeholder(now: Date()))
        } else {
            completion(TaskLensWidgetEntry(date: Date(), snapshot: snapshot))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TaskLensWidgetEntry>) -> Void) {
        completion(TaskLensTimeline.timeline(snapshot: current(), now: Date()))
    }
}

struct TaskLensWidgetView: View {
    let entry: TaskLensWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(.background, for: .widget)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemSmall:
            QuickActionsWidgetView { destination in
                Button(intent: OpenDestinationIntent(destination)) {
                    WidgetActionTile(destination)
                }
                .buttonStyle(.plain)
            }
        case .systemLarge:
            WorkspaceWidgetView(snapshot: entry.snapshot)
        default:
            RecentSessionsWidgetView(snapshot: entry.snapshot)
        }
    }
}

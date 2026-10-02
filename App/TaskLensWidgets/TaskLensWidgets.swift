import ActivityKit
import SwiftUI
import TLCoreServices
import TLDomain
import TLLocalization
import TLDesignSystem
import TLNavigation
import WidgetKit
import WidgetsFeature

@main
struct TaskLensWidgetBundle: WidgetBundle {
    var body: some Widget {
        TaskLensWidget()
        SessionLiveActivity()
        ScreenLensLiveActivity()
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

/// The Live Activity of an ongoing session. On iPhones with the Dynamic Island
/// it has compact, minimal and expanded forms; every iPhone shows the Lock
/// Screen form. Tapping it opens the session (Open); Resume opens it where
/// the user stopped; Stop ends the session.
struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            SessionActivityLockScreenView(
                attributes: context.attributes,
                state: context.state,
                isStale: context.isStale
            ) {
                SessionActivityButtons(sessionID: context.attributes.sessionID)
            }
            .widgetURL(DeepLink.session(context.attributes.sessionID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        SessionActivityTitle(context.attributes, context.state)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: context.attributes.kind.symbolName)
                    }
                    .font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SessionActivityClock(context.state)
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: 80, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        SessionActivityModeLine(context.state)
                        HStack {
                            SessionActivityCounts(context.state)
                            Spacer(minLength: 8)
                            SessionActivityButtons(sessionID: context.attributes.sessionID)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.attributes.kind.symbolName)
                    .foregroundStyle(.tint)
                    .accessibilityLabel(Text(L10nKey.sessionKind(context.attributes.kind)))
            } compactTrailing: {
                SessionActivityCompactTrailing(context.state)
            } minimal: {
                SessionActivityMinimal(context.attributes, context.state)
            }
            .widgetURL(DeepLink.session(context.attributes.sessionID))
        }
    }
}

/// Resume (opens TaskLens) and Stop (ends the session without opening it).
struct SessionActivityButtons: View {
    let sessionID: SessionID

    var body: some View {
        HStack(spacing: 8) {
            SessionActivityResumeLink(sessionID)
            Button(intent: StopSessionIntent(sessionID: sessionID)) {
                Label {
                    Text(L10nKey.activityStop)
                } icon: {
                    Image(systemName: "stop.fill")
                }
                .font(.caption.weight(.semibold))
            }
            .tint(.red)
        }
    }
}

/// The Screen Lens Live Activity: shown only while the user's own capture is
/// running (with the time left and Capture / Stop), then briefly with what
/// Lens found. Tapping it opens Lens with the results.
struct ScreenLensLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScreenLensActivityAttributes.self) { context in
            ScreenLensActivityLockScreenView(state: context.state) {
                ScreenLensActivityButtons(state: context.state)
            }
            .widgetURL(DeepLink.lens)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ScreenLensActivityHeadline(context.state)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ScreenLensActivityClock(context.state)
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: 80, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .top) {
                        ScreenLensActivityHighlights(context.state)
                        Spacer(minLength: 8)
                        ScreenLensActivityButtons(state: context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
                    .accessibilityLabel(Text(L10nKey.screenLensActivityLive))
            } compactTrailing: {
                ScreenLensActivityClock(context.state)
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
                    .accessibilityLabel(Text(L10nKey.screenLensActivityLive))
            }
            .widgetURL(DeepLink.lens)
        }
    }
}

/// Capture and Stop while live; nothing once the capture is over.
struct ScreenLensActivityButtons: View {
    let state: ScreenLensStatus

    var body: some View {
        if state.phase == .live {
            HStack(spacing: 8) {
                Button(intent: CaptureScreenIntent()) {
                    Label {
                        Text(L10nKey.screenLensCapture)
                    } icon: {
                        Image(systemName: "camera.viewfinder")
                    }
                    .font(.caption.weight(.semibold))
                }
                Button(intent: StopScreenLensIntent()) {
                    Label {
                        Text(L10nKey.screenLensStop)
                    } icon: {
                        Image(systemName: "stop.fill")
                    }
                    .font(.caption.weight(.semibold))
                }
                .tint(.red)
            }
        } else if state.phase == .countdown {
            Button(intent: StopScreenLensIntent()) {
                Label {
                    Text(L10nKey.screenLensStop)
                } icon: {
                    Image(systemName: "stop.fill")
                }
                .font(.caption.weight(.semibold))
            }
            .tint(.red)
        }
    }
}

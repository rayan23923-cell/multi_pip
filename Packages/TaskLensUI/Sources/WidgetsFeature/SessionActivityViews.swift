import ActivityKit
import SwiftUI
import TLCoreServices
import TLDesignSystem
import TLDomain
import TLLocalization
import TLNavigation

/// The Live Activity of one TaskLens session. Static values are set when the
/// activity starts; `ContentState` changes with each update.
public struct SessionActivityAttributes: ActivityAttributes, Sendable {
    public typealias ContentState = SessionActivityContent

    public var sessionID: SessionID
    public var kind: SessionKind
    public var workspaceName: String

    public init(sessionID: SessionID, kind: SessionKind, workspaceName: String) {
        self.sessionID = sessionID
        self.kind = kind
        self.workspaceName = workspaceName
    }
}

// MARK: Pieces shared by the Lock Screen and the Dynamic Island

/// The session's name: its title, or "Research Session".
public struct SessionActivityTitle: View {
    let attributes: SessionActivityAttributes
    let state: SessionActivityContent

    public init(_ attributes: SessionActivityAttributes, _ state: SessionActivityContent) {
        self.attributes = attributes
        self.state = state
    }

    public var body: some View {
        if let title = state.title {
            Text(verbatim: title)
        } else {
            Text(verbatim: L10n.format(.activitySessionTitle, L10n.string(L10nKey.sessionKind(attributes.kind))))
        }
    }
}

/// Elapsed session time, or the focus countdown. Both run live without updates.
public struct SessionActivityClock: View {
    let state: SessionActivityContent

    public init(_ state: SessionActivityContent) {
        self.state = state
    }

    public var body: some View {
        Group {
            if state.mode == .timer, let end = state.focusEndsAt, end > state.startedAt {
                Text(timerInterval: state.startedAt...end, countsDown: true)
                    .accessibilityLabel(Text(L10nKey.activityRemaining))
            } else {
                Text(state.startedAt, style: .timer)
                    .accessibilityLabel(Text(L10nKey.activityElapsed))
            }
        }
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    }
}

/// Links, notes and documents collected so far.
public struct SessionActivityCounts: View {
    let state: SessionActivityContent

    public init(_ state: SessionActivityContent) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 12) {
            count(state.links, symbol: "link", key: .activityLinks)
            count(state.notes, symbol: "note.text", key: .activityNotes)
            count(state.documents, symbol: "doc", key: .activityDocuments)
        }
        .font(.caption.monospacedDigit())
    }

    private func count(_ value: Int, symbol: String, key: L10nKey) -> some View {
        Label {
            Text(value, format: .number)
        } icon: {
            Image(systemName: symbol)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: L10n.format(key, value)))
    }
}

/// The line that changes with the mode: processing progress, focus, or the task at hand.
public struct SessionActivityModeLine: View {
    let state: SessionActivityContent

    public init(_ state: SessionActivityContent) {
        self.state = state
    }

    public var body: some View {
        switch state.mode {
        case .processing:
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(verbatim: state.processingTitle ?? L10n.string(.activityProcessing))
                } icon: {
                    Image(systemName: "gearshape.2")
                }
                .font(.caption)
                if let progress = state.progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
        case .timer:
            Label {
                Text(L10nKey.activityFocus)
            } icon: {
                Image(systemName: "timer")
            }
            .font(.caption)
        case .task:
            Label {
                Text(verbatim: L10n.string(.activityTask) + ": " + (state.taskTitle ?? ""))
            } icon: {
                Image(systemName: "star.fill")
            }
            .font(.caption)
            .lineLimit(1)
        case .session:
            EmptyView()
        }
    }
}

// MARK: Lock Screen (and the banner on iPhones without the Dynamic Island)

public struct SessionActivityLockScreenView<Actions: View>: View {
    let attributes: SessionActivityAttributes
    let state: SessionActivityContent
    let isStale: Bool
    let actions: Actions

    public init(
        attributes: SessionActivityAttributes,
        state: SessionActivityContent,
        isStale: Bool,
        @ViewBuilder actions: () -> Actions
    ) {
        self.attributes = attributes
        self.state = state
        self.isStale = isStale
        self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: attributes.kind.symbolName)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    SessionActivityTitle(attributes, state)
                        .font(.headline)
                        .lineLimit(1)
                    Text(verbatim: attributes.workspaceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                SessionActivityClock(state)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: 90, alignment: .trailing)
            }
            SessionActivityModeLine(state)
            HStack {
                SessionActivityCounts(state)
                Spacer(minLength: 8)
                actions
            }
            if isStale {
                Text(L10nKey.activityStale)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

/// The Resume link: opens the session in TaskLens where the user stopped.
public struct SessionActivityResumeLink: View {
    let sessionID: SessionID

    public init(_ sessionID: SessionID) {
        self.sessionID = sessionID
    }

    public var body: some View {
        Link(destination: DeepLink.resume(sessionID)) {
            Label {
                Text(L10nKey.activityResume)
            } icon: {
                Image(systemName: "play.fill")
            }
            .font(.caption.weight(.semibold))
        }
    }
}

// MARK: Dynamic Island

public struct SessionActivityCompactTrailing: View {
    let state: SessionActivityContent

    public init(_ state: SessionActivityContent) {
        self.state = state
    }

    public var body: some View {
        if state.mode == .processing {
            if let progress = state.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
            } else {
                Image(systemName: "gearshape.2")
                    .accessibilityLabel(Text(L10nKey.activityProcessing))
            }
        } else {
            SessionActivityClock(state)
                .frame(maxWidth: 52)
        }
    }
}

public struct SessionActivityMinimal: View {
    let attributes: SessionActivityAttributes
    let state: SessionActivityContent

    public init(_ attributes: SessionActivityAttributes, _ state: SessionActivityContent) {
        self.attributes = attributes
        self.state = state
    }

    public var body: some View {
        switch state.mode {
        case .processing:
            if let progress = state.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
            } else {
                Image(systemName: "gearshape.2")
                    .accessibilityLabel(Text(L10nKey.activityProcessing))
            }
        case .timer:
            Image(systemName: "timer")
                .accessibilityLabel(Text(L10nKey.activityFocus))
        case .task:
            Image(systemName: "star.fill")
                .accessibilityLabel(Text(L10nKey.activityTask))
        case .session:
            Image(systemName: attributes.kind.symbolName)
                .accessibilityLabel(Text(L10nKey.sessionKind(attributes.kind)))
        }
    }
}

import ActivityKit
import SwiftUI
import TLCoreServices
import TLDesignSystem
import TLLocalization

/// The Live Activity shown while Screen Lens is capturing: a visible status
/// (with the time left before it stops on its own) and Capture / Stop
/// buttons that work from any screen. After a capture it shows what Lens found.
public struct ScreenLensActivityAttributes: ActivityAttributes, Sendable {
    public typealias ContentState = ScreenLensStatus

    public init() {}
}

/// "Screen Lens is on", "Capturing in 3 s…", "Reading…" or "Lens found".
public struct ScreenLensActivityHeadline: View {
    let state: ScreenLensStatus

    public init(_ state: ScreenLensStatus) {
        self.state = state
    }

    public var body: some View {
        Label {
            switch state.phase {
            case .live: Text(L10nKey.screenLensActivityLive)
            case .countdown: Text(L10nKey.screenLensActivityCountdown)
            case .reading: Text(L10nKey.screenLensReading)
            case .found: Text(L10nKey.screenLensFound)
            case .nothing: Text(L10nKey.screenLensNothing)
            }
        } icon: {
            Image(systemName: symbol)
        }
    }

    private var symbol: String {
        switch state.phase {
        case .live, .countdown: "record.circle"
        case .reading: "text.viewfinder"
        case .found, .nothing: "viewfinder"
        }
    }
}

/// Time left: the capture countdown, or until the stream stops on its own.
public struct ScreenLensActivityClock: View {
    let state: ScreenLensStatus

    public init(_ state: ScreenLensStatus) {
        self.state = state
    }

    public var body: some View {
        Group {
            if state.phase == .countdown, let captureAt = state.captureAt, captureAt > state.liveSince {
                Text(timerInterval: state.liveSince...captureAt, countsDown: true)
            } else if state.phase == .live, state.endsAt > state.liveSince {
                Text(timerInterval: state.liveSince...state.endsAt, countsDown: true)
                    .accessibilityLabel(Text(L10nKey.screenLensActivityStopsIn))
            }
        }
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    }
}

/// The highlights ("💰 $199"), one per line.
public struct ScreenLensActivityHighlights: View {
    let state: ScreenLensStatus

    public init(_ state: ScreenLensStatus) {
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(state.highlights, id: \.self) { line in
                Text(verbatim: line)
                    .lineLimit(1)
            }
        }
        .font(.callout)
    }
}

public struct ScreenLensActivityLockScreenView<Actions: View>: View {
    let state: ScreenLensStatus
    let actions: Actions

    public init(state: ScreenLensStatus, @ViewBuilder actions: () -> Actions) {
        self.state = state
        self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ScreenLensActivityHeadline(state)
                    .font(.headline)
                Spacer(minLength: 8)
                ScreenLensActivityClock(state)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: 90, alignment: .trailing)
            }
            if !state.highlights.isEmpty {
                ScreenLensActivityHighlights(state)
            } else if state.phase == .live {
                Text(L10nKey.screenLensActivityHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                actions
            }
        }
        .padding()
    }
}

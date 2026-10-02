import SwiftUI
import TLCoreServices
import TLDesignSystem
import TLDomain
import TLLocalization

/// Screen Lens in the Lens screen: Start, a clear status while capturing
/// (with Capture and Stop), and "Lens found" afterwards.
struct ScreenLensSection: View {
    let model: ScreenLensModel

    var body: some View {
        Section {
            content
        } header: {
            // A text style, so the header follows the user's text size in full.
            Text(L10nKey.screenLensSection)
                .font(.footnote)
        } footer: {
            Text(model.state == .unavailable ? L10nKey.screenLensUnavailableFooter : L10nKey.screenLensPrivacy)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .unavailable:
            Label {
                Text(L10nKey.screenLensUnavailable)
            } icon: {
                Image(systemName: "rectangle.dashed.badge.record")
            }
            .accessibilityIdentifier("screenLens.unavailable")

        case .idle, .done, .stopped, .failed:
            if let message {
                Text(message)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("screenLens.message")
            }
            Button { model.start() } label: {
                TLLabel(model.state == .idle ? .screenLensStart : .screenLensStartAgain, systemImage: "rectangle.dashed.badge.record")
            }
            .accessibilityIdentifier("screenLens.start")

        case .choosing:
            HStack {
                ProgressView()
                Text(L10nKey.screenLensChoosing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("screenLens.choosing")
            stopButton

        case .live:
            ScreenLensStatusRow(model: model)
            Text(L10nKey.screenLensCaptureHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                model.captureFrame()
            } label: {
                TLLabel(.screenLensCapture, systemImage: "camera.viewfinder")
            }
            .accessibilityIdentifier("screenLens.capture")
            stopButton

        case .countdown:
            ScreenLensStatusRow(model: model)
            stopButton

        case .reading:
            HStack {
                ProgressView()
                Text(L10nKey.screenLensReading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("screenLens.reading")
        }
    }

    private var stopButton: some View {
        Button(role: .destructive) { model.stop() } label: {
            TLLabel(.screenLensStop, systemImage: "stop.fill")
        }
        .accessibilityIdentifier("screenLens.stop")
    }

    private var message: L10nKey? {
        switch model.state {
        case .stopped(.user): .screenLensStoppedUser
        case .stopped(.timeLimit): .screenLensStoppedTimeLimit
        case .stopped(.system): .screenLensStoppedSystem
        case .stopped(.cancelled): .screenLensStoppedCancelled
        case .failed(.couldNotStart): .screenLensFailedStart
        case .failed(.streamFailed): .screenLensStoppedSystem
        case .failed(.noFrame): .screenLensFailedNoFrame
        case .failed(.unreadable): .lensImageFailed
        default: nil
        }
    }
}

/// "Screen Lens is on" with the time left, or the capture countdown. Always
/// visible while capturing, next to iOS's own recording indicator.
struct ScreenLensStatusRow: View {
    let model: ScreenLensModel

    var body: some View {
        HStack {
            Image(systemName: "record.circle")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if case .countdown(let captureAt) = model.state {
                    Text(L10nKey.screenLensActivityCountdown)
                    Text(timerInterval: Date.now...max(captureAt, .now), countsDown: true)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10nKey.screenLensActivityLive)
                    if let endsAt = model.session.endsAt {
                        HStack(spacing: 4) {
                            Text(L10nKey.screenLensActivityStopsIn)
                            Text(timerInterval: Date.now...max(endsAt, .now), countsDown: true)
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("screenLens.status")
    }
}

/// "Lens found": only the most useful findings, each with its top actions.
/// Tapping one shows its actions below; nothing runs on its own.
struct ScreenLensFoundSection: View {
    let model: ScreenLensModel

    var body: some View {
        Section {
            if model.highlights.isEmpty {
                Text(L10nKey.screenLensNothing)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("screenLens.nothing")
            }
            ForEach(model.highlights) { highlight in
                Button {
                    model.results.selectedID = highlight.finding.id
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: TLSpacing.s) {
                        Text(verbatim: highlight.symbol)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: highlight.finding.text)
                                .lineLimit(2)
                                .foregroundStyle(.primary)
                            if highlight.finding.certainty == .possible {
                                Text(L10nKey.lensImagePossible)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.orange)
                            } else if !highlight.actions.isEmpty {
                                Text(verbatim: actionNames(highlight.actions))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if model.results.selectedID == highlight.finding.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityHint(Text(L10nKey.lensImageSelect))
                .accessibilityIdentifier("screenLens.highlight")
            }
            Button(role: .destructive) { model.clear() } label: {
                TLLabel(.screenLensClear, systemImage: "trash")
            }
            .accessibilityIdentifier("screenLens.clear")
        } header: {
            Text(L10nKey.screenLensFound)
        }
    }

    private func actionNames(_ actions: [ActionType]) -> String {
        actions
            .compactMap { type in L10nKey(rawValue: type.defaultTitleKey).map { L10n.string($0) } }
            .joined(separator: " · ")
    }
}

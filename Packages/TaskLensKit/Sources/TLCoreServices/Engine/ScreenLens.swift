import Foundation
import TLDomain

/// Screen Lens: reading what is on screen, only when the user asks.
///
/// Flow: the user taps Start → the system content-sharing picker
/// (ScreenCaptureKit) → the system shows its recording indicator while the
/// stream runs → the user taps Capture → one frame → Vision → Context Engine
/// → Action Engine. The stream stops after that capture (or on Stop, or at
/// the time limit). Only the newest frame is kept, in memory, and it is
/// dropped when the stream stops; nothing is written to disk or sent anywhere.
///
/// This type is the lifecycle as plain values, so every state is tested
/// without a device. The model drives the real capture from it.
public struct ScreenLensSession: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// Nothing running. The start of every flow.
        case idle
        /// This device or OS can't capture the screen (before iOS 27, or
        /// screen recording is restricted). Screenshots still work through Lens.
        case unavailable
        /// The system picker is up; nothing is captured until the user picks.
        case choosing
        /// The stream runs and the system recording indicator is visible.
        case live
        /// The user asked for a frame; it is taken at `captureAt` so they can
        /// get back to the screen they want read (for example after tapping
        /// Capture in the Live Activity).
        case countdown(captureAt: Date)
        /// The frame is being read. The stream is already stopped.
        case reading
        /// Results are shown. The stream is stopped.
        case done
        /// The stream ended without a result.
        case stopped(StopReason)
        case failed(Failure)
    }

    public enum StopReason: String, Sendable, Equatable {
        /// The user tapped Stop (in the app, the Live Activity, or the system indicator).
        case user
        /// Live longer than `maximumLiveDuration` without a capture.
        case timeLimit
        /// The system ended the stream (another app took over the screen, the
        /// device locked, or the user stopped it from Control Center).
        case system
        /// The user cancelled the picker.
        case cancelled
    }

    public enum Failure: String, Sendable, Equatable {
        /// The picker or stream could not start (often: screen recording is restricted).
        case couldNotStart
        /// The stream stopped with an error.
        case streamFailed
        /// No frame arrived (for example the screen was protected content).
        case noFrame
        /// Vision could not read the frame.
        case unreadable
    }

    public enum Event: Sendable, Equatable {
        case start
        case pickerCancelled
        case pickerFailed
        case streamStarted
        case capture(delay: TimeInterval)
        case frameTaken
        case noFrame
        case analysisFinished(success: Bool)
        case stop
        case streamEnded(error: Bool)
        case tick
        case reset
    }

    /// A stream is never left running unattended for longer than this.
    public static let maximumLiveDuration: TimeInterval = 5 * 60
    /// Time to get back to the screen to read after tapping Capture.
    public static let defaultCaptureDelay: TimeInterval = 3
    public static let maximumCaptureDelay: TimeInterval = 10

    public private(set) var state: State
    /// When the stream started; nil while nothing is live.
    public private(set) var liveSince: Date?

    public init(isAvailable: Bool) {
        state = isAvailable ? .idle : .unavailable
    }

    /// True while the screen is being captured: the system indicator is on
    /// and the app must show its own status and a Stop button.
    public var isCapturing: Bool {
        switch state {
        case .live, .countdown: true
        default: false
        }
    }

    /// True while the picker or a stream is in progress: Start is not offered.
    public var isBusy: Bool {
        switch state {
        case .choosing, .live, .countdown, .reading: true
        default: false
        }
    }

    public var canStart: Bool {
        switch state {
        case .unavailable, .choosing, .live, .countdown, .reading: false
        default: true
        }
    }

    public var canCapture: Bool { state == .live }

    /// When the stream will stop on its own if nothing is captured.
    public var endsAt: Date? { liveSince.map { $0.addingTimeInterval(Self.maximumLiveDuration) } }

    /// What the model must do next.
    public enum Effect: Sendable, Equatable {
        case presentPicker
        case stopStream
        case takeFrame
        /// Drop any frame held in memory.
        case discardFrames
    }

    /// Applies an event. Events that don't fit the current state are ignored
    /// (for example a late frame after Stop), so a race never restarts capture.
    @discardableResult
    public mutating func handle(_ event: Event, now: Date) -> [Effect] {
        switch (state, event) {
        case (.unavailable, _):
            return []

        case (_, .start) where canStart:
            state = .choosing
            liveSince = nil
            return [.discardFrames, .presentPicker]

        case (.choosing, .pickerCancelled):
            state = .stopped(.cancelled)
            return []
        case (.choosing, .pickerFailed):
            state = .failed(.couldNotStart)
            return []
        case (.choosing, .streamStarted):
            state = .live
            liveSince = now
            return []

        case (.live, .capture(let delay)):
            let delay = min(max(delay, 0), Self.maximumCaptureDelay)
            if delay == 0 {
                return takeFrame()
            }
            state = .countdown(captureAt: now.addingTimeInterval(delay))
            return []

        case (.countdown(let captureAt), .tick) where now >= captureAt:
            return takeFrame()
        case (.live, .tick), (.countdown, .tick):
            if let endsAt, now >= endsAt {
                return end(.stopped(.timeLimit))
            }
            return []

        case (.reading, .frameTaken):
            return []
        case (.reading, .noFrame):
            state = .failed(.noFrame)
            return [.discardFrames]
        case (.reading, .analysisFinished(let success)):
            state = success ? .done : .failed(.unreadable)
            return [.discardFrames]

        case (.choosing, .stop), (.live, .stop), (.countdown, .stop):
            return end(.stopped(.user))
        case (.live, .streamEnded(let error)), (.countdown, .streamEnded(let error)):
            liveSince = nil
            state = error ? .failed(.streamFailed) : .stopped(.system)
            return [.discardFrames]
        case (.choosing, .streamEnded):
            state = .failed(.couldNotStart)
            return [.discardFrames]

        case (.done, .reset), (.stopped, .reset), (.failed, .reset):
            state = .idle
            return [.discardFrames]

        default:
            return []
        }
    }

    private mutating func takeFrame() -> [Effect] {
        state = .reading
        liveSince = nil
        // One frame, then the stream stops: nothing keeps watching the screen.
        return [.takeFrame, .stopStream]
    }

    private mutating func end(_ newState: State) -> [Effect] {
        state = newState
        liveSince = nil
        return [.stopStream, .discardFrames]
    }
}

/// The short "Lens found" line: the most useful findings, each with an
/// emoji and its top actions ("💰 $199 · Convert, Calculate, Save").
public struct LensHighlight: Sendable, Equatable, Identifiable {
    public var finding: LensFinding
    public var symbol: String
    /// The first few recommended actions; empty for a possible match, which
    /// the user must check before anything is offered.
    public var actions: [ActionType]

    public var id: String { finding.id }

    public static let maximumHighlights = 3
    public static let maximumActions = 3

    /// The highlights of a report: confident findings first, never "All text"
    /// unless nothing else was found.
    public static func highlights(of report: LensReport, source: ContextSource) -> [LensHighlight] {
        var findings = report.findings.filter { $0.source != .allText }
        if findings.isEmpty, let all = report.findings.first(where: { $0.source == .allText }) {
            findings = [all]
        }
        return findings.prefix(maximumHighlights).map { finding in
            let actions: [ActionType]
            if finding.certainty == .confident {
                let analysis = ActionEngine.analyze(finding.content, context: ActionContext(source: source))
                actions = Array(analysis.suggestions.primary.map(\.type).prefix(maximumActions))
            } else {
                actions = []
            }
            return LensHighlight(finding: finding, symbol: symbol(for: finding), actions: actions)
        }
    }

    public static func symbol(for finding: LensFinding) -> String {
        switch finding.source {
        case .allText: return "📝"
        case .code(.qr): return "🔳"
        case .code(.barcode): return "🏷️"
        case .text:
            switch finding.entityType {
            case .currencyAmount: return "💰"
            case .phoneNumber: return "📞"
            case .url: return "🔗"
            case .email: return "✉️"
            case .date: return "📅"
            case .address: return "📍"
            case .code, .json: return "💻"
            default: return "🔢"
            }
        }
    }
}

/// What the Screen Lens Live Activity shows. Plain values, shared with the
/// widget extension. No frame and no full text: only the short status line.
public struct ScreenLensStatus: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Hashable, Sendable {
        case live
        case countdown
        case reading
        case found
        case nothing
    }

    public var phase: Phase
    public var liveSince: Date
    /// When the stream stops on its own.
    public var endsAt: Date
    public var captureAt: Date?
    /// "💰 $199" lines, at most `LensHighlight.maximumHighlights`, each cut short.
    public var highlights: [String]

    public static let maximumHighlightLength = 40

    public init(phase: Phase, liveSince: Date, endsAt: Date, captureAt: Date? = nil, highlights: [String] = []) {
        self.phase = phase
        self.liveSince = liveSince
        self.endsAt = endsAt
        self.captureAt = captureAt
        self.highlights = highlights
    }

    public static func line(for highlight: LensHighlight) -> String {
        let text = highlight.finding.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let short = text.count > maximumHighlightLength ? String(text.prefix(maximumHighlightLength - 1)) + "…" : text
        return "\(highlight.symbol) \(short)"
    }
}

/// Shows the Screen Lens status outside the app (a Live Activity) so the user
/// can capture or stop from any screen. Optional: a no-op where unavailable.
@MainActor
public protocol ScreenLensStatusPublishing: AnyObject {
    func show(_ status: ScreenLensStatus) async
    /// Ends the status; `final` stays briefly on the Lock Screen when given.
    func end(final: ScreenLensStatus?) async
}

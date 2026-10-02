import Foundation
import Testing
import TLCoreServices
import TLDomain

@Suite("Screen Lens lifecycle")
struct ScreenLensSessionTests {
    let start = Date(timeIntervalSinceReferenceDate: 50_000)

    func live() -> ScreenLensSession {
        var session = ScreenLensSession(isAvailable: true)
        session.handle(.start, now: start)
        session.handle(.streamStarted, now: start)
        return session
    }

    @Test func nothingHappensWhereCaptureIsUnavailable() {
        var session = ScreenLensSession(isAvailable: false)
        #expect(session.state == .unavailable)
        #expect(!session.canStart)
        #expect(session.handle(.start, now: start).isEmpty)
        #expect(session.handle(.streamStarted, now: start).isEmpty)
        #expect(session.state == .unavailable)
        #expect(!session.isCapturing)
    }

    @Test func startOnlyShowsThePicker() {
        var session = ScreenLensSession(isAvailable: true)
        #expect(session.state == .idle)
        #expect(session.handle(.start, now: start) == [.discardFrames, .presentPicker])
        #expect(session.state == .choosing)
        // The picker is up: nothing is captured yet and capture can't be asked for.
        #expect(!session.isCapturing)
        #expect(session.handle(.capture(delay: 0), now: start).isEmpty)
        #expect(session.handle(.start, now: start).isEmpty, "No second picker")
    }

    @Test func pickerCancelAndFailureEndCleanly() {
        var cancelled = ScreenLensSession(isAvailable: true)
        cancelled.handle(.start, now: start)
        cancelled.handle(.pickerCancelled, now: start)
        #expect(cancelled.state == .stopped(.cancelled))
        #expect(cancelled.canStart)

        var failed = ScreenLensSession(isAvailable: true)
        failed.handle(.start, now: start)
        failed.handle(.pickerFailed, now: start)
        #expect(failed.state == .failed(.couldNotStart))
    }

    @Test func liveShowsStatusAndAStopTime() {
        let session = live()
        #expect(session.state == .live)
        #expect(session.isCapturing)
        #expect(session.canCapture)
        #expect(session.endsAt == start.addingTimeInterval(ScreenLensSession.maximumLiveDuration))
    }

    @Test func captureNowTakesOneFrameAndStopsTheStream() {
        var session = live()
        #expect(session.handle(.capture(delay: 0), now: start) == [.takeFrame, .stopStream])
        #expect(session.state == .reading)
        #expect(!session.isCapturing)
        #expect(session.handle(.analysisFinished(success: true), now: start) == [.discardFrames])
        #expect(session.state == .done)
        #expect(session.canStart)
    }

    @Test func countdownWaitsThenCaptures() {
        var session = live()
        let at = start.addingTimeInterval(10)
        #expect(session.handle(.capture(delay: 3), now: at).isEmpty)
        #expect(session.state == .countdown(captureAt: at.addingTimeInterval(3)))
        #expect(session.isCapturing)
        #expect(session.handle(.tick, now: at.addingTimeInterval(2)).isEmpty)
        #expect(session.handle(.tick, now: at.addingTimeInterval(3)) == [.takeFrame, .stopStream])
        #expect(session.state == .reading)
    }

    @Test func delayIsLimited() {
        var session = live()
        session.handle(.capture(delay: 600), now: start)
        #expect(session.state == .countdown(captureAt: start.addingTimeInterval(ScreenLensSession.maximumCaptureDelay)))
    }

    @Test func stopEndsEverythingAndDropsFrames() {
        var session = live()
        #expect(session.handle(.stop, now: start) == [.stopStream, .discardFrames])
        #expect(session.state == .stopped(.user))
        #expect(session.endsAt == nil)

        var counting = live()
        counting.handle(.capture(delay: 3), now: start)
        counting.handle(.stop, now: start)
        #expect(counting.state == .stopped(.user))
        // A late tick does not capture after Stop.
        #expect(counting.handle(.tick, now: start.addingTimeInterval(5)).isEmpty)
    }

    @Test func forgottenStreamStopsAtTheTimeLimit() {
        var session = live()
        #expect(session.handle(.tick, now: start.addingTimeInterval(60)).isEmpty)
        let effects = session.handle(.tick, now: start.addingTimeInterval(ScreenLensSession.maximumLiveDuration))
        #expect(effects == [.stopStream, .discardFrames])
        #expect(session.state == .stopped(.timeLimit))
    }

    @Test func systemEndingTheStreamIsShown() {
        var stopped = live()
        stopped.handle(.streamEnded(error: false), now: start)
        #expect(stopped.state == .stopped(.system))

        var failed = live()
        failed.handle(.streamEnded(error: true), now: start)
        #expect(failed.state == .failed(.streamFailed))
    }

    @Test func missingOrUnreadableFramesFail() {
        var noFrame = live()
        noFrame.handle(.capture(delay: 0), now: start)
        noFrame.handle(.noFrame, now: start)
        #expect(noFrame.state == .failed(.noFrame))

        var unreadable = live()
        unreadable.handle(.capture(delay: 0), now: start)
        unreadable.handle(.analysisFinished(success: false), now: start)
        #expect(unreadable.state == .failed(.unreadable))
    }

    @Test func resetAndRestart() {
        var session = live()
        session.handle(.capture(delay: 0), now: start)
        session.handle(.analysisFinished(success: true), now: start)
        #expect(session.handle(.reset, now: start) == [.discardFrames])
        #expect(session.state == .idle)
        #expect(session.handle(.start, now: start) == [.discardFrames, .presentPicker])
    }

    @Test func lateEventsAreIgnored() {
        var session = ScreenLensSession(isAvailable: true)
        // A stream callback with nothing running does nothing.
        #expect(session.handle(.streamStarted, now: start).isEmpty)
        #expect(session.handle(.frameTaken, now: start).isEmpty)
        #expect(session.state == .idle)
    }
}

@Suite("Screen Lens results")
struct ScreenLensHighlightTests {
    func report(_ lines: [String], confidence: Double = 0.95) -> LensReport {
        VisualLensAnalyzer.report(for: VisualRecognition(lines: lines.enumerated().map { index, text in
            RecognizedLine(text: text, confidence: confidence, box: .init(x: 0.1, y: 0.9 - Double(index) * 0.1, width: 0.6, height: 0.05))
        }))
    }

    func highlight(_ lines: [String], confidence: Double = 0.95) -> [LensHighlight] {
        LensHighlight.highlights(of: report(lines, confidence: confidence), source: .screenCapture)
    }

    @Test func priceOffersConvertCalculateSave() throws {
        let money = try #require(highlight(["$199"]).first)
        #expect(money.finding.entityType == .currencyAmount)
        #expect(money.symbol == "💰")
        #expect(money.actions == [.convertCurrency, .calculate, .saveToSession])
        #expect(ScreenLensStatus.line(for: money) == "💰 $199")
    }

    @Test func phoneOffersCallAndMessage() throws {
        let phone = try #require(highlight(["Call 0771 234 5678"]).first { $0.finding.entityType == .phoneNumber })
        #expect(phone.symbol == "📞")
        #expect(phone.actions.contains(.call))
        #expect(phone.actions.contains(.sendMessage))
    }

    @Test func linkOffersOpen() throws {
        let link = try #require(highlight(["https://example.com/offer"]).first)
        #expect(link.finding.entityType == .url)
        #expect(link.symbol == "🔗")
        #expect(link.actions.first == .openURL)
    }

    @Test func meetingIsADateCandidate() throws {
        let date = try #require(highlight(["Meeting tomorrow 10 AM"]).first { $0.finding.entityType == .date })
        #expect(date.symbol == "📅")
        #expect(date.actions.contains(.addToCalendar))
    }

    @Test func codeIsACodeCandidate() {
        let found = highlight(["func total() -> Int {", "return price * 2;", "}"])
        #expect(found.contains { $0.finding.entityType == .code && $0.symbol == "💻" })
    }

    @Test func onlyTheMostUsefulFewAreShown() {
        let found = highlight(["$199", "https://a.example", "Call 0771 234 5678", "mail@example.com", "$45"])
        #expect(found.count == LensHighlight.maximumHighlights)
        #expect(found.allSatisfy { $0.actions.count <= LensHighlight.maximumActions })
        #expect(!found.contains { $0.finding.source == .allText })
    }

    @Test func possibleMatchHasNoActions() throws {
        let unsure = try #require(highlight(["$1O5"], confidence: 0.5).first)
        #expect(unsure.finding.certainty == .possible)
        #expect(unsure.actions.isEmpty)
    }

    @Test func plainTextFallsBackToAllText() throws {
        let text = try #require(highlight(["Just some words here"]).first)
        #expect(text.finding.source == .allText)
        #expect(text.symbol == "📝")
    }

    @Test func statusLinesAreShortAndCarryNoFrame() throws {
        let long = String(repeating: "word ", count: 30)
        let text = try #require(highlight([long]).first)
        let line = ScreenLensStatus.line(for: text)
        #expect(line.count <= ScreenLensStatus.maximumHighlightLength + 3)
        let status = ScreenLensStatus(phase: .found, liveSince: .now, endsAt: .now, highlights: [line])
        let data = try JSONEncoder().encode(status)
        #expect(data.count < 1_024, "Live Activity content stays small")
    }
}

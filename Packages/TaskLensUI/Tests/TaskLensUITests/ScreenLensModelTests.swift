import CoreGraphics
import Foundation
import Testing
import TLCoreServices
import TLData
import TLDomain
import TLFoundation
import UIKit
@testable import LensFeature

/// Stands in for ScreenCaptureKit: the test plays the system picker's part.
@MainActor
final class FakeScreenCapture: ScreenCapturing {
    var isAvailable = true
    var frame: CGImage?
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var framesTaken = 0
    private var onEvent: (@MainActor (ScreenCaptureEvent) -> Void)?

    func start(onEvent: @escaping @MainActor (ScreenCaptureEvent) -> Void) {
        starts += 1
        self.onEvent = onEvent
    }

    func send(_ event: ScreenCaptureEvent) {
        onEvent?(event)
    }

    func currentFrame() -> CGImage? {
        framesTaken += 1
        return frame
    }

    func stop() async {
        stops += 1
        frame = nil
    }
}

@MainActor
final class FakeScreenLensStatus: ScreenLensStatusPublishing {
    private(set) var shown: [ScreenLensStatus] = []
    private(set) var ended: [ScreenLensStatus?] = []

    func show(_ status: ScreenLensStatus) async { shown.append(status) }
    func end(final status: ScreenLensStatus?) async { ended.append(status) }
}

@MainActor
@Suite("Screen Lens model", .serialized)
struct ScreenLensModelTests {
    let repositories = Repositories.inMemory()
    let clock = ManualDateProvider(Date(timeIntervalSinceReferenceDate: 70_000))
    let capture = FakeScreenCapture()
    let status = FakeScreenLensStatus()

    func model(_ recognition: VisualRecognition = VisualRecognition(lines: [
        RecognizedLine(text: "$199", confidence: 0.97, box: .init(x: 0.1, y: 0.8, width: 0.4, height: 0.1)),
    ])) -> ScreenLensModel {
        let sessions = SessionService(workspaces: repositories.workspaces, sessions: repositories.sessions, clock: clock, logger: .disabled())
        let captureService = CaptureService(sessions: repositories.sessions, contextItems: repositories.contextItems, clock: clock, logger: .disabled())
        return ScreenLensModel(
            capture: capture,
            results: ImageLensModel(recognizer: FakeRecognizer(result: recognition), captureService: captureService, sessionService: sessions),
            status: status,
            clock: clock
        )
    }

    static func frame() -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }.cgImage!
    }

    /// Lets the model's small tasks (stop, read, status) finish.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test func unavailableDeviceOffersNoCapture() async {
        capture.isAvailable = false
        let lens = model()
        #expect(lens.state == .unavailable)
        lens.start()
        #expect(capture.starts == 0)
        #expect(lens.state == .unavailable)
    }

    @Test func fullFlowReadsOneFrameAndStops() async throws {
        let lens = model()
        lens.start()
        #expect(lens.state == .choosing)
        #expect(capture.starts == 1)
        #expect(status.shown.isEmpty, "Nothing is shown before the user picks")

        capture.frame = Self.frame()
        capture.send(.started)
        await settle()
        #expect(lens.state == .live)
        #expect(status.shown.last?.phase == .live)

        lens.captureFrame(after: 0)
        await settle()
        #expect(capture.framesTaken == 1)
        #expect(capture.stops >= 1, "The stream stops right after the frame")
        #expect(lens.state == .done)
        let money = try #require(lens.highlights.first)
        #expect(money.finding.entityType == .currencyAmount)
        #expect(money.actions == [.convertCurrency, .calculate, .saveToSession])
        #expect(lens.results.preview == nil, "The frame is not kept")
        #expect(lens.results.savedIDs.isEmpty, "Nothing is saved on its own")
        #expect(status.ended.last??.highlights == ["💰 $199"])

        lens.clear()
        #expect(lens.state == .idle)
        #expect(lens.highlights.isEmpty)
        #expect(lens.results.report == nil)
    }

    @Test func countdownCapturesAfterTheDelay() async {
        let lens = model()
        lens.start()
        capture.frame = Self.frame()
        capture.send(.started)
        lens.captureFrame(after: 3)
        if case .countdown = lens.state {} else { Issue.record("Expected countdown, got \(lens.state)") }
        await settle()
        #expect(status.shown.last?.phase == .countdown)
        lens.tick()
        #expect(capture.framesTaken == 0)
        clock.advance(by: 3)
        lens.tick()
        await settle()
        #expect(capture.framesTaken == 1)
        #expect(lens.state == .done)
    }

    @Test func stopEndsTheStreamAndTheStatus() async {
        let lens = model()
        lens.start()
        capture.send(.started)
        await settle()
        lens.stop()
        await settle()
        #expect(lens.state == .stopped(.user))
        #expect(capture.stops == 1)
        #expect(capture.framesTaken == 0)
        #expect(status.ended.count == 1)
    }

    @Test func timeLimitStopsAForgottenStream() async {
        let lens = model()
        lens.start()
        capture.send(.started)
        clock.advance(by: ScreenLensSession.maximumLiveDuration)
        lens.tick()
        await settle()
        #expect(lens.state == .stopped(.timeLimit))
        #expect(capture.stops == 1)
    }

    @Test func pickerCancelFailureAndSystemStop() async {
        let lens = model()
        lens.start()
        capture.send(.cancelled)
        #expect(lens.state == .stopped(.cancelled))

        lens.start()
        capture.send(.failed)
        #expect(lens.state == .failed(.couldNotStart))

        lens.start()
        capture.send(.started)
        capture.send(.ended(error: false))
        #expect(lens.state == .stopped(.system))
        #expect(capture.starts == 3)
    }

    @Test func noFrameIsReported() async {
        let lens = model()
        lens.start()
        capture.send(.started)
        lens.captureFrame(after: 0)
        await settle()
        #expect(lens.state == .failed(.noFrame))
    }

    @Test func possibleMatchIsNotActionable() async throws {
        let lens = model(VisualRecognition(lines: [RecognizedLine(text: "$1O5", confidence: 0.4)]))
        lens.start()
        capture.frame = Self.frame()
        capture.send(.started)
        lens.captureFrame(after: 0)
        await settle()
        let unsure = try #require(lens.highlights.first)
        #expect(unsure.finding.certainty == .possible)
        #expect(unsure.actions.isEmpty)
        #expect(lens.results.analysis(for: unsure.finding) == nil)
    }
}

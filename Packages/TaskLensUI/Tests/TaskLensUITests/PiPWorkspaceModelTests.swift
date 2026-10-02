import AVFoundation
import CoreMedia
import Foundation
import PiPFeature
import Testing
import TLCoreServices
import TLData
import TLDomain
import TLFoundation
import TLNavigation

/// Stands in for AVKit: records calls and lets the test send system events.
@MainActor
final class FakePictureInPictureEngine: PictureInPictureEngine {
    var onEvent: (@MainActor (PiPEngineEvent) -> Void)?
    let isSupported: Bool
    var isPossible: Bool
    var isActive = false
    let sourceLayer: CALayer? = CALayer()
    var frames = 0
    var startCalls = 0
    var stopCalls = 0
    var startsAutomatically = false

    init(supported: Bool = true, possible: Bool = true) {
        isSupported = supported
        isPossible = possible
    }

    func display(_ frame: CMSampleBuffer) { frames += 1 }
    func start() { startCalls += 1 }
    func stop() { stopCalls += 1 }
    func setStartsAutomatically(_ enabled: Bool) { startsAutomatically = enabled }

    func send(_ event: PiPEngineEvent) {
        if case .didStart = event { isActive = true }
        if case .didStop = event { isActive = false }
        onEvent?(event)
    }
}

@MainActor
private struct PiPHarness {
    let repositories = Repositories.inMemory()
    let clock = ManualDateProvider(Date(timeIntervalSinceReferenceDate: 9_000))

    var service: PiPWorkspaceService {
        PiPWorkspaceService(cards: repositories.pipCards, presentation: repositories.pipPresentation, clock: clock, logger: .disabled())
    }

    func model(_ engine: FakePictureInPictureEngine) -> PiPWorkspaceModel {
        PiPWorkspaceModel(service: service, engine: engine, clock: clock)
    }

    func note(_ text: String) -> ToolOutput {
        NoteService.output(for: Note(title: text, body: "\(text) body", createdAt: clock.now()))
    }
}

/// Lets fire-and-forget work started by the model (saving state, handling
/// a notification) finish.
@MainActor
private func settle() async {
    try? await Task.sleep(for: .milliseconds(150))
}

@MainActor
@Suite("Picture in Picture model", .serialized)
struct PiPWorkspaceModelTests {
    @Test func unsupportedDeviceNeverStarts() async {
        let harness = PiPHarness()
        let engine = FakePictureInPictureEngine(supported: false, possible: false)
        let model = harness.model(engine)
        await model.load()
        await model.keep(harness.note("A"), workspaceID: nil)
        #expect(model.status == .unsupported)
        #expect(!model.isSupported)
        #expect(!model.canStart)
        model.start()
        #expect(engine.startCalls == 0)
        #expect(engine.frames == 0)
        // Cards are still kept for when the user returns to TaskLens.
        #expect(model.cards.count == 1)
    }

    @Test func nothingToShowCannotStart() async {
        let engine = FakePictureInPictureEngine()
        let model = PiPHarness().model(engine)
        await model.load()
        #expect(model.status == .idle)
        #expect(!model.canStart)
        model.start()
        #expect(engine.startCalls == 0)
    }

    @Test func startStopRecordsState() async throws {
        let harness = PiPHarness()
        let engine = FakePictureInPictureEngine()
        let model = harness.model(engine)
        await model.load()
        await model.keep(harness.note("A"), workspaceID: nil)
        #expect(engine.frames >= 1)
        #expect(model.canStart)

        model.start()
        #expect(model.status == .starting)
        #expect(engine.startCalls == 1)
        engine.send(.didStart)
        #expect(model.status == .active)
        await settle()
        #expect(try await harness.service.presentation().isRunning)

        model.stop()
        #expect(model.status == .stopping)
        #expect(engine.stopCalls == 1)
        engine.send(.didStop(restored: false))
        #expect(model.status == .idle)
        #expect(model.lastStop == .user)
        await settle()
        let presentation = try await harness.service.presentation()
        #expect(!presentation.isRunning && presentation.stopReason == .user)
    }

    @Test func notPossibleRightNow() async {
        let harness = PiPHarness()
        let engine = FakePictureInPictureEngine(possible: false)
        let model = harness.model(engine)
        await model.keep(harness.note("A"), workspaceID: nil)
        #expect(!model.canStart)
        engine.send(.possibleChanged(true))
        #expect(model.canStart)
        engine.send(.possibleChanged(false))
        #expect(!model.canStart)
    }

    @Test func failingToStartIsReported() async throws {
        let harness = PiPHarness()
        let engine = FakePictureInPictureEngine()
        let model = harness.model(engine)
        await model.keep(harness.note("A"), workspaceID: nil)
        model.start()
        engine.send(.failedToStart)
        #expect(model.status == .idle)
        #expect(model.lastStop == .failed)
    }

    @Test func tappingTheWindowRestoresTheCardsOrigin() async throws {
        let harness = PiPHarness()
        let engine = FakePictureInPictureEngine()
        let model = harness.model(engine)
        var restored: [PiPCard] = []
        model.onRestore = { restored.append($0) }
        let note = Note(title: "Plan", body: "Steps", createdAt: harness.clock.now())
        await model.keep(NoteService.output(for: note), workspaceID: nil)
        model.start()
        engine.send(.didStart)

        engine.send(.restoreRequested)
        engine.send(.didStop(restored: true))
        #expect(restored.map(\.origin.noteID) == [note.id])
        #expect(AppRoute.restoring(try #require(restored.first)) == .note(note.id))
        #expect(model.status == .idle)
        #expect(model.lastStop == nil)
        await settle()
        #expect(try await harness.service.presentation().stopReason == .restored)
    }

    @Test func interruptionIsRecordedWhenIOSClosesTheWindow() async throws {
        let harness = PiPHarness()
        let engine = FakePictureInPictureEngine()
        let model = harness.model(engine)
        await model.keep(harness.note("A"), workspaceID: nil)
        model.start()
        engine.send(.didStart)

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        await settle()
        engine.send(.didStop(restored: false))
        #expect(model.lastStop == .interrupted)

        // When the interruption ends the frame is drawn again.
        let frames = engine.frames
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
        )
        await settle()
        #expect(engine.frames > frames)
    }

    @Test func pagingUpdatesTheWindow() async {
        let harness = PiPHarness()
        let engine = FakePictureInPictureEngine()
        let model = harness.model(engine)
        await model.keep(harness.note("A"), workspaceID: nil)
        await model.keep(harness.note("B"), workspaceID: nil)
        await model.keep(harness.note("C"), workspaceID: nil)
        #expect(model.currentCard?.title == "C")
        #expect(model.currentIndex == 2)

        let frames = engine.frames
        await model.step(by: -1)
        #expect(model.currentCard?.title == "B")
        #expect(engine.frames > frames)

        engine.send(.skip(-1))
        await settle()
        #expect(model.currentCard?.title == "A")

        await model.select(model.cards[2])
        #expect(model.currentCard?.title == "C")

        engine.send(.needsFrame)
        #expect(engine.frames > frames + 2)
    }

    @Test func removingTheLastCardStopsTheWindow() async throws {
        let harness = PiPHarness()
        let engine = FakePictureInPictureEngine()
        let model = harness.model(engine)
        await model.keep(harness.note("A"), workspaceID: nil)
        model.start()
        engine.send(.didStart)
        await model.remove(try #require(model.cards.first))
        #expect(model.cards.isEmpty)
        #expect(engine.stopCalls == 1)
    }

    @Test func previewEnablesAutomaticStartOnlyWithCards() async {
        let harness = PiPHarness()
        let engine = FakePictureInPictureEngine()
        let model = harness.model(engine)
        model.setPreviewVisible(true)
        #expect(!engine.startsAutomatically)
        await model.keep(harness.note("A"), workspaceID: nil)
        model.setPreviewVisible(true)
        #expect(engine.startsAutomatically)
        model.setPreviewVisible(false)
        #expect(!engine.startsAutomatically)
    }

    @Test func appClosedWhileRunningIsExplainedAtNextLaunch() async throws {
        let harness = PiPHarness()
        let engine = FakePictureInPictureEngine()
        let model = harness.model(engine)
        await model.keep(harness.note("A"), workspaceID: nil)
        await model.keep(harness.note("B"), workspaceID: nil)
        await model.step(by: -1)
        model.start()
        engine.send(.didStart)
        await settle()
        // The app is closed here: no stop event ever arrives.

        let relaunched = harness.model(FakePictureInPictureEngine())
        await relaunched.load(afterLaunch: true)
        #expect(relaunched.lastStop == .appClosed)
        #expect(relaunched.status == .idle)
        #expect(relaunched.cards.map(\.title) == ["A", "B"])
        #expect(relaunched.currentCard?.title == "A")
    }

    @Test func keepingFromASessionItem() async {
        let harness = PiPHarness()
        let model = harness.model(FakePictureInPictureEngine())
        let item = ContextItem(sessionID: SessionID(), source: .manualEntry, content: .text("Gate 12"), createdAt: harness.clock.now())
        await model.keep(item)
        #expect(model.currentCard?.body == "Gate 12")
        #expect(AppRoute.restoring(model.currentCard!) == .session(item.sessionID!))
    }
}

@MainActor
@Suite("Picture in Picture frames")
struct PiPFrameRendererTests {
    @Test func cardBecomesAVideoFrame() throws {
        let card = PiPCard(kind: .calculation, title: "125×3", body: "= 375", createdAt: Date())
        let renderer = PiPFrameRenderer()
        for appearance in [
            PiPFrameRenderer.Appearance(colorScheme: .light),
            PiPFrameRenderer.Appearance(colorScheme: .dark, layoutDirection: .rightToLeft, locale: Locale(identifier: "ar")),
        ] {
            let sample = try #require(renderer.sampleBuffer(for: card, position: 0, count: 1, appearance: appearance))
            let image = try #require(CMSampleBufferGetImageBuffer(sample))
            #expect(CVPixelBufferGetWidth(image) == Int(PiPCardView.size.width * PiPFrameRenderer.scale))
            #expect(CVPixelBufferGetHeight(image) == Int(PiPCardView.size.height * PiPFrameRenderer.scale))
            #expect(CMSampleBufferIsValid(sample))
        }
        #expect(renderer.sampleBuffer(for: nil, position: 0, count: 0, appearance: .init()) != nil)
    }
}

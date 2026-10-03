import Foundation
import Testing
import TLCoreServices
import TLDomain
import TLFoundation

/// Returns a fixed presentation, or throws.
private struct StubLoader: PresentationLoading {
    let result: Result<PresentationDocument, TaskLensError>

    func loadPresentation() async throws -> PresentationDocument {
        try result.get()
    }
}

/// Holds the load open until the test releases it.
private final class GateLoader: PresentationLoading, @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    let presentation: PresentationDocument

    init(_ presentation: PresentationDocument) {
        (stream, continuation) = AsyncStream.makeStream()
        self.presentation = presentation
    }

    func release() { continuation.yield() }

    func loadPresentation() async throws -> PresentationDocument {
        for await _ in stream { break }
        return presentation
    }
}

private func makePresentation(slides count: Int, type: PresentationSourceType = .pdf) -> PresentationDocument {
    let documentID = DocumentID()
    return PresentationDocument(
        documentID: documentID,
        title: "Deck",
        sourceType: type,
        slides: (0..<count).map { PresentationSlide(index: $0, source: .pdfPage(documentID, pageIndex: $0)) },
        createdAt: Date(timeIntervalSinceReferenceDate: 1_000)
    )
}

@MainActor
private func loadedEngine(slides count: Int, startAt: Int = 0) async -> PresentationEngine {
    let engine = PresentationEngine()
    await engine.load(from: StubLoader(result: .success(makePresentation(slides: count))), startAt: startAt)
    return engine
}

@MainActor
@Suite("Presentation engine")
struct PresentationEngineTests {
    // MARK: Loading

    @Test func startsIdleAndEmpty() {
        let engine = PresentationEngine()
        #expect(engine.phase == .idle)
        #expect(engine.document == nil)
        #expect(engine.currentSlideContent == nil)
        let moved = engine.next(), played = engine.play(), jumped = engine.goToSlide(0)
        #expect(!moved && !played && !jumped)
    }

    @Test func loadReachesReadyOnTheFirstSlide() async {
        let engine = PresentationEngine()
        let presentation = makePresentation(slides: 12)
        let loaded = await engine.load(from: StubLoader(result: .success(presentation)))
        #expect(loaded)
        #expect(engine.phase == .ready)
        #expect(engine.document == presentation)
        #expect(engine.currentSlide == 0)
        #expect(engine.slideCount == 12)
        #expect(engine.currentSlideContent == presentation.slides[0])
    }

    @Test func loadStartsAtAClampedSlide() async {
        let engine = await loadedEngine(slides: 5, startAt: 3)
        #expect(engine.currentSlide == 3)
        let clamped = await loadedEngine(slides: 5, startAt: 40)
        #expect(clamped.currentSlide == 4)
    }

    @Test func emptyPresentationIsAnError() async {
        let engine = PresentationEngine()
        let loaded = await engine.load(from: StubLoader(result: .success(makePresentation(slides: 0))))
        #expect(!loaded)
        #expect(engine.phase == .error(.empty))
    }

    @Test(arguments: [
        (TaskLensError.validationFailed(.emptyContent), PresentationFailure.empty),
        (TaskLensError.unsupportedContent(type: "pptx"), PresentationFailure.unsupportedSource),
        (TaskLensError.notFound(entity: "document", id: "x"), PresentationFailure.unreadable),
    ])
    func loaderErrorsBecomeFailures(error: TaskLensError, failure: PresentationFailure) async {
        let engine = PresentationEngine()
        let loaded = await engine.load(from: StubLoader(result: .failure(error)))
        #expect(!loaded)
        #expect(engine.phase == .error(failure))
        #expect(engine.document == nil)
        let played = engine.play()
        #expect(!played)
    }

    @Test func unsupportedSourceTypeIsRejected() async {
        let engine = PresentationEngine()
        let loaded = await engine.load(from: StubLoader(result: .success(makePresentation(slides: 3, type: .powerpoint))))
        #expect(!loaded)
        #expect(engine.phase == .error(.unsupportedSource))
        #expect(engine.document == nil)
    }

    @Test func secondLoadWhileLoadingIsIgnoredAndResetDropsALateResult() async {
        let engine = PresentationEngine()
        let gate = GateLoader(makePresentation(slides: 4))
        let pending = Task { await engine.load(from: gate) }
        while engine.phase != .loading { await Task.yield() }

        let second = await engine.load(from: StubLoader(result: .success(makePresentation(slides: 9))))
        #expect(!second)
        #expect(engine.phase == .loading)

        engine.reset()
        gate.release()
        let first = await pending.value
        #expect(!first)
        #expect(engine.phase == .idle)
        #expect(engine.document == nil)
    }

    @Test func reloadReplacesThePresentation() async {
        let engine = await loadedEngine(slides: 3, startAt: 2)
        let replacement = makePresentation(slides: 7)
        let loaded = await engine.load(from: StubLoader(result: .success(replacement)))
        #expect(loaded)
        #expect(engine.document == replacement)
        #expect(engine.currentSlide == 0)
        #expect(engine.slideCount == 7)
    }

    // MARK: Navigation

    @Test func nextAndPreviousStopAtTheBoundaries() async {
        let engine = await loadedEngine(slides: 3)
        let backAtFirst = engine.previous()
        #expect(!backAtFirst)
        let first = engine.next(), second = engine.next(), pastLast = engine.next()
        #expect(first && second && !pastLast)
        #expect(engine.currentSlide == 2)
        #expect(engine.phase == .ready)
        let back = engine.previous()
        #expect(back)
        #expect(engine.currentSlide == 1)
        #expect(engine.currentSlideContent?.displayNumber == 2)
    }

    @Test func goToSlideRejectsInvalidIndexes() async {
        let engine = await loadedEngine(slides: 48, startAt: 5)
        let tooLow = engine.goToSlide(-1), tooHigh = engine.goToSlide(48), same = engine.goToSlide(5)
        #expect(!tooLow && !tooHigh && !same)
        #expect(engine.currentSlide == 5)
        let last = engine.goToSlide(47)
        #expect(last)
        #expect(engine.currentSlide == 47)
        #expect(engine.state.displaySlideNumber == 48)
    }

    // MARK: Playback

    @Test func playPauseResumeStop() async {
        let engine = await loadedEngine(slides: 5, startAt: 2)
        let resumedTooEarly = engine.resume(), pausedTooEarly = engine.pause()
        #expect(!resumedTooEarly && !pausedTooEarly)

        let played = engine.play()
        #expect(played)
        #expect(engine.phase == .playing)
        #expect(engine.currentSlide == 2)

        let paused = engine.pause()
        #expect(paused)
        #expect(engine.phase == .paused)
        let moved = engine.next()
        #expect(moved)
        #expect(engine.phase == .paused)

        let resumed = engine.resume()
        #expect(resumed)
        #expect(engine.phase == .playing)
        #expect(engine.currentSlide == 3)
        let resumedAgain = engine.resume()
        #expect(!resumedAgain)

        let stopped = engine.stop()
        #expect(stopped)
        #expect(engine.phase == .ready)
        #expect(engine.currentSlide == 3)
        let stoppedAgain = engine.stop()
        #expect(!stoppedAgain)
    }

    @Test func startAlwaysBeginsAtTheFirstSlide() async {
        let engine = await loadedEngine(slides: 6, startAt: 4)
        let started = engine.start()
        #expect(started)
        #expect(engine.phase == .playing)
        #expect(engine.currentSlide == 0)
        let startedAgain = engine.start()
        #expect(!startedAgain)
        engine.goToSlide(3)
        let restarted = engine.start()
        #expect(restarted)
        #expect(engine.currentSlide == 0)
        #expect(engine.phase == .playing)
    }

    @Test func playingPastTheLastSlideCompletes() async {
        let engine = await loadedEngine(slides: 2)
        engine.play()
        engine.next()
        let finished = engine.next()
        #expect(finished)
        #expect(engine.phase == .completed)
        #expect(engine.currentSlide == 1)
        let resumed = engine.resume()
        #expect(!resumed)
        let replayed = engine.play()
        #expect(replayed)
        #expect(engine.phase == .playing)
        #expect(engine.currentSlide == 0)
    }

    @Test func startFromCompletedPlaysAgain() async {
        let engine = await loadedEngine(slides: 1)
        engine.play()
        engine.next()
        #expect(engine.phase == .completed)
        let started = engine.start()
        #expect(started)
        #expect(engine.phase == .playing)
    }

    @Test func playingNeverAdvancesOnItsOwn() async throws {
        let engine = await loadedEngine(slides: 10)
        engine.play()
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.currentSlide == 0)
        #expect(engine.phase == .playing)
    }

    @Test func resetReturnsToIdle() async {
        let engine = await loadedEngine(slides: 4, startAt: 2)
        engine.play()
        engine.reset()
        #expect(engine.phase == .idle)
        #expect(engine.document == nil)
        #expect(engine.slideCount == 0)
    }

    @Test(arguments: [10, 50, 100])
    func walksEverySlide(count: Int) async {
        let engine = await loadedEngine(slides: count)
        engine.play()
        var visited = [engine.currentSlide]
        while engine.next(), engine.phase == .playing {
            visited.append(engine.currentSlide)
        }
        #expect(visited == Array(0..<count))
        #expect(engine.phase == .completed)

        for expected in stride(from: count - 2, through: 0, by: -1) {
            let back = engine.previous()
            #expect(back)
            #expect(engine.currentSlide == expected)
        }
        #expect(engine.phase == .paused)
        let jumped = engine.goToSlide(count / 2)
        #expect(jumped)
        #expect(engine.currentSlide == count / 2)
    }
}

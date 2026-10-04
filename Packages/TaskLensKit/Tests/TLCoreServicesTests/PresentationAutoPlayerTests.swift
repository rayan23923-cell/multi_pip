import CoreGraphics
import Foundation
import Testing
import TLCoreServices
import TLDomain
import TLFoundation
import UniformTypeIdentifiers

/// Gives the test control of time: each sleep waits until the test calls `fire()`.
///
/// It also counts how many sleeps wait at once, which is how many countdowns
/// are alive. With `honorsCancellation` false, a cancelled sleep still waits
/// for `fire()`, like a task that is already past its cancellation check.
private final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private let honorsCancellation: Bool
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
    private var cancelledEarly: Set<UUID> = []
    private var _durations: [Duration] = []
    private var _mostAtOnce = 0

    init(honorsCancellation: Bool = true) {
        self.honorsCancellation = honorsCancellation
    }

    var pending: Int { lock.withLock { waiters.count } }
    var mostAtOnce: Int { lock.withLock { _mostAtOnce } }
    var durations: [Duration] { lock.withLock { _durations } }

    var sleep: PresentationAutoPlayer.Sleep {
        { [self] duration in try await self.wait(duration) }
    }

    private func wait(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.withLock {
                    _durations.append(duration)
                    if cancelledEarly.remove(id) != nil {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    waiters.append((id, continuation))
                    _mostAtOnce = max(_mostAtOnce, waiters.count)
                }
            }
        } onCancel: {
            guard honorsCancellation else { return }
            let removed: CheckedContinuation<Void, any Error>? = lock.withLock {
                guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                    cancelledEarly.insert(id)
                    return nil
                }
                return waiters.remove(at: index).continuation
            }
            removed?.resume(throwing: CancellationError())
        }
    }

    /// Ends the oldest waiting sleep. False when nothing is waiting.
    @discardableResult
    func fire() -> Bool {
        let first = lock.withLock { waiters.isEmpty ? nil : waiters.removeFirst() }
        first?.continuation.resume()
        return first != nil
    }
}

/// Waits, letting other tasks run, until `condition` holds or two seconds pass.
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

private func makePresentation(slides count: Int) -> PresentationDocument {
    let documentID = DocumentID()
    return PresentationDocument(
        documentID: documentID,
        title: "Deck",
        sourceType: .pdf,
        slides: (0..<count).map { PresentationSlide(index: $0, source: .pdfPage(documentID, pageIndex: $0)) },
        createdAt: Date(timeIntervalSinceReferenceDate: 1_000)
    )
}

private struct FixedLoader: PresentationLoading {
    let presentation: PresentationDocument
    func loadPresentation() async throws -> PresentationDocument { presentation }
}

@MainActor
private func loadedEngine(slides count: Int) async -> PresentationEngine {
    let engine = PresentationEngine()
    await engine.load(from: FixedLoader(presentation: makePresentation(slides: count)))
    return engine
}

/// A PDF with `pages` blank pages.
private func makePDF(pages: Int) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 100, height: 100)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: &box, nil)
    else { return Data() }
    for _ in 0..<pages {
        context.beginPDFPage(nil)
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

@MainActor
@Suite("Presentation auto play")
struct PresentationAutoPlayerTests {
    /// Lets one interval pass and waits for the player to act on it.
    private func tick(_ sleeper: ManualSleeper, _ player: PresentationAutoPlayer) async {
        #expect(await eventually { sleeper.pending == 1 }, "A countdown should be waiting")
        let before = player.engine.currentSlide
        sleeper.fire()
        #expect(await eventually {
            sleeper.pending == 1 || !player.hasCountdown || player.engine.currentSlide != before
        })
        // Let the countdown reach its next sleep (or end).
        _ = await eventually { sleeper.pending == 1 || !player.hasCountdown }
    }

    // MARK: Play, pause, resume, stop

    @Test func playAdvancesOneSlidePerInterval() async {
        let engine = await loadedEngine(slides: 10)
        let sleeper = ManualSleeper()
        let player = PresentationAutoPlayer(engine: engine, interval: 5, sleep: sleeper.sleep)

        #expect(player.play())
        #expect(engine.phase == .playing)
        #expect(engine.currentSlide == 0, "Playing starts on the current slide")
        for expected in 1...3 {
            await tick(sleeper, player)
            #expect(engine.currentSlide == expected)
        }
        #expect(engine.phase == .playing)
        #expect(sleeper.durations.allSatisfy { $0 == .seconds(5) })
        #expect(sleeper.mostAtOnce == 1)
    }

    @Test func pauseStopsAdvancing() async {
        let engine = await loadedEngine(slides: 10)
        let sleeper = ManualSleeper()
        let player = PresentationAutoPlayer(engine: engine, interval: 5, sleep: sleeper.sleep)
        player.play()
        await tick(sleeper, player)
        #expect(engine.currentSlide == 1)

        #expect(player.pause())
        #expect(engine.phase == .paused)
        #expect(!player.hasCountdown)
        #expect(await eventually { sleeper.pending == 0 }, "The countdown is cancelled, not left sleeping")
        #expect(!sleeper.fire())
        try? await Task.sleep(for: .milliseconds(20))
        #expect(engine.currentSlide == 1)
    }

    @Test func resumeContinuesFromTheCurrentSlide() async {
        let engine = await loadedEngine(slides: 10)
        let sleeper = ManualSleeper()
        let player = PresentationAutoPlayer(engine: engine, interval: 5, sleep: sleeper.sleep)
        player.play()
        await tick(sleeper, player)
        await tick(sleeper, player)
        player.pause()
        #expect(engine.currentSlide == 2)

        #expect(player.resume())
        #expect(engine.phase == .playing)
        #expect(engine.currentSlide == 2, "Resuming does not skip a slide")
        await tick(sleeper, player)
        #expect(engine.currentSlide == 3)
        // Play on a paused presentation resumes too.
        player.pause()
        #expect(player.play())
        await tick(sleeper, player)
        #expect(engine.currentSlide == 4)
    }

    @Test func stopEndsPlaybackAndKeepsTheSlide() async {
        let engine = await loadedEngine(slides: 10)
        let sleeper = ManualSleeper()
        let player = PresentationAutoPlayer(engine: engine, interval: 5, sleep: sleeper.sleep)
        player.play()
        await tick(sleeper, player)

        #expect(player.stop())
        #expect(engine.phase == .ready)
        #expect(engine.currentSlide == 1)
        #expect(!player.hasCountdown)
        #expect(await eventually { sleeper.pending == 0 })
        #expect(!player.stop(), "Stopping twice changes nothing")
        #expect(!player.pause())
        #expect(!player.resume())

        // Playing again starts from where it stopped.
        player.play()
        await tick(sleeper, player)
        #expect(engine.currentSlide == 2)
    }

    // MARK: Last slide

    @Test func lastSlideCompletesWithoutLooping() async {
        let engine = await loadedEngine(slides: 3)
        let sleeper = ManualSleeper()
        let player = PresentationAutoPlayer(engine: engine, interval: 5, sleep: sleeper.sleep)
        player.play()
        await tick(sleeper, player)
        await tick(sleeper, player)
        #expect(engine.currentSlide == 2)
        #expect(engine.phase == .playing)

        // One more interval on the last slide completes the presentation.
        await tick(sleeper, player)
        #expect(engine.phase == .completed)
        #expect(engine.currentSlide == 2, "It stays on the last slide")
        #expect(!player.hasCountdown)
        #expect(await eventually { sleeper.pending == 0 })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(engine.currentSlide == 2)

        // Only an explicit Play starts again, from the first slide.
        #expect(player.play())
        #expect(engine.currentSlide == 0)
        #expect(engine.phase == .playing)
    }

    @Test func oneSlideCompletesAfterOneInterval() async {
        let engine = await loadedEngine(slides: 1)
        let sleeper = ManualSleeper()
        let player = PresentationAutoPlayer(engine: engine, interval: 5, sleep: sleeper.sleep)
        player.play()
        await tick(sleeper, player)
        #expect(engine.phase == .completed)
        #expect(engine.currentSlide == 0)
        #expect(!player.hasCountdown)
    }

    // MARK: One countdown at a time

    @Test func repeatedPlayKeepsOneCountdown() async {
        let engine = await loadedEngine(slides: 10)
        let sleeper = ManualSleeper()
        let player = PresentationAutoPlayer(engine: engine, interval: 5, sleep: sleeper.sleep)
        #expect(player.play())
        #expect(!player.play(), "Play while playing does nothing")
        #expect(!player.play())
        #expect(!player.resume())
        #expect(await eventually { sleeper.pending == 1 })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(sleeper.pending == 1)
        await tick(sleeper, player)
        #expect(engine.currentSlide == 1, "One interval moves one slide")
        #expect(sleeper.mostAtOnce == 1)
    }

    @Test func rapidCommandsLeaveAtMostOneCountdown() async {
        let engine = await loadedEngine(slides: 50)
        let sleeper = ManualSleeper()
        let player = PresentationAutoPlayer(engine: engine, interval: 5, sleep: sleeper.sleep)
        for round in 0..<50 {
            player.play()
            player.pause()
            player.resume()
            player.setInterval(round % 2 == 0 ? 10 : 15)
            player.slideChangedByUser()
            if round % 3 == 0 { player.stop() }
            player.play()
            await Task.yield()
        }
        #expect(await eventually { sleeper.pending == 1 })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(sleeper.pending == 1)
        #expect(sleeper.mostAtOnce == 1)
        #expect(engine.currentSlide == 0, "No command advanced a slide")
    }

    @Test func aReplacedCountdownCannotAdvance() async {
        let engine = await loadedEngine(slides: 10)
        // These sleeps ignore cancellation, so the old countdown wakes up later.
        let sleeper = ManualSleeper(honorsCancellation: false)
        let player = PresentationAutoPlayer(engine: engine, interval: 5, sleep: sleeper.sleep)
        player.play()
        #expect(await eventually { sleeper.pending == 1 })
        player.pause()
        player.resume()
        #expect(await eventually { sleeper.pending == 2 })

        // The first (replaced) countdown wakes: nothing moves.
        sleeper.fire()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(engine.currentSlide == 0)
        // The live one moves exactly one slide.
        sleeper.fire()
        #expect(await eventually { engine.currentSlide == 1 })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(engine.currentSlide == 1)
    }

    // MARK: Manual navigation and intervals

    @Test func manualNavigationGivesTheNewSlideAFullInterval() async {
        let engine = await loadedEngine(slides: 10)
        let sleeper = ManualSleeper()
        let player = PresentationAutoPlayer(engine: engine, interval: 5, sleep: sleeper.sleep)
        player.play()
        #expect(await eventually { sleeper.pending == 1 })

        engine.goToSlide(6)
        player.slideChangedByUser()
        #expect(await eventually { sleeper.durations.count == 2 }, "The countdown started again")
        await tick(sleeper, player)
        #expect(engine.currentSlide == 7)
        #expect(sleeper.mostAtOnce == 1)

        // A manual move while paused starts nothing.
        player.pause()
        engine.previous()
        player.slideChangedByUser()
        #expect(!player.hasCountdown)
        #expect(engine.phase == .paused)
    }

    @Test(arguments: PresentationAutoPlayer.presetIntervals)
    func presetIntervalsAreUsed(seconds: Int) async {
        let engine = await loadedEngine(slides: 3)
        let sleeper = ManualSleeper()
        let player = PresentationAutoPlayer(engine: engine, interval: seconds, sleep: sleeper.sleep)
        #expect(player.interval == seconds)
        player.play()
        #expect(await eventually { sleeper.pending == 1 })
        #expect(sleeper.durations == [.seconds(seconds)])
    }

    @Test func intervalsAreClampedAndChangeTheRunningCountdown() async {
        let engine = await loadedEngine(slides: 10)
        let sleeper = ManualSleeper()
        #expect(PresentationAutoPlayer.presetIntervals == [5, 10, 15, 30, 60])
        #expect(PresentationAutoPlayer(engine: engine).interval == 10)
        #expect(PresentationAutoPlayer(engine: engine, interval: 0).interval == 1)
        let player = PresentationAutoPlayer(engine: engine, interval: 5, sleep: sleeper.sleep)
        player.setInterval(99_999)
        #expect(player.interval == 3600)
        player.setInterval(45)
        #expect(player.interval == 45, "A custom interval")

        player.play()
        #expect(await eventually { sleeper.pending == 1 })
        player.setInterval(30)
        #expect(await eventually { sleeper.pending == 1 })
        #expect(sleeper.durations == [.seconds(45), .seconds(30)])
        #expect(sleeper.mostAtOnce == 1)
        player.setInterval(30)
        #expect(sleeper.durations.count == 2, "The same interval does not restart the countdown")
    }

    // MARK: Sizes

    @Test(arguments: [10, 50, 100])
    func playsThroughEverySlideOnce(count: Int) async {
        let engine = await loadedEngine(slides: count)
        let sleeper = ManualSleeper()
        let player = PresentationAutoPlayer(engine: engine, interval: 5, sleep: sleeper.sleep)
        let started = ContinuousClock.now
        player.play()
        var visited = [engine.currentSlide]
        for _ in 1..<count {
            await tick(sleeper, player)
            visited.append(engine.currentSlide)
        }
        #expect(visited == Array(0..<count))
        await tick(sleeper, player)
        #expect(engine.phase == .completed)
        #expect(engine.currentSlide == count - 1)
        #expect(sleeper.mostAtOnce == 1)
        print("AUTOPLAY \(count) slides: \(ContinuousClock.now - started) of test overhead for \(count) intervals")
    }

    // MARK: Lifetime

    @Test func droppingThePlayerEndsItsCountdown() async {
        let engine = await loadedEngine(slides: 10)
        let sleeper = ManualSleeper()
        weak var released: PresentationAutoPlayer?
        do {
            let player = PresentationAutoPlayer(engine: engine, interval: 5, sleep: sleeper.sleep)
            released = player
            player.play()
            #expect(await eventually { sleeper.pending == 1 })
        }
        // The countdown does not keep the player alive.
        #expect(released == nil)
        sleeper.fire()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(sleeper.pending == 0, "The orphaned countdown ends instead of sleeping again")
        #expect(engine.currentSlide == 0)
    }

    @Test func aNewPresentationStartsWithoutPlayback() async {
        let sleeper = ManualSleeper()
        let first = PresentationAutoPlayer(engine: await loadedEngine(slides: 10), interval: 5, sleep: sleeper.sleep)
        first.play()
        await tick(sleeper, first)
        first.stop()

        // Reopening builds a new engine and player.
        let engine = await loadedEngine(slides: 10)
        let second = PresentationAutoPlayer(engine: engine, interval: 5, sleep: sleeper.sleep)
        #expect(!second.hasCountdown)
        #expect(engine.phase == .ready)
        #expect(engine.currentSlide == 0)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(sleeper.pending == 0)
    }

    @Test func theRealClockAdvancesASlide() async {
        let engine = await loadedEngine(slides: 3)
        let player = PresentationAutoPlayer(engine: engine, interval: 1)
        player.play()
        let deadline = ContinuousClock.now + .seconds(5)
        while engine.currentSlide == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(engine.currentSlide == 1)
        player.stop()
        #expect(!player.hasCountdown)
    }

    // MARK: Separation from the reader

    @Test func autoPlayNeverChangesTheReadingPage() async throws {
        let env = TestEnvironment()
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = env.documents(in: directory)
        let pdf = try await service.importData(makePDF(pages: 20), filename: "Deck.pdf", contentType: .pdf)
        _ = try await service.setLastReadPage(pdf.id, page: 7)
        let before = try await service.document(id: pdf.id)

        let engine = PresentationEngine()
        await engine.load(from: PDFPresentationLoader(documentID: pdf.id, documentService: service, clock: env.clock))
        #expect(engine.slideCount == 20)
        let sleeper = ManualSleeper()
        let player = PresentationAutoPlayer(engine: engine, interval: 5, sleep: sleeper.sleep)
        player.play()
        for _ in 0..<5 { await tick(sleeper, player) }
        player.pause()
        player.resume()
        await tick(sleeper, player)
        player.stop()
        #expect(engine.currentSlide == 6)

        let after = try await service.document(id: pdf.id)
        #expect(after.lastReadPage == 7)
        #expect(after == before)
    }
}

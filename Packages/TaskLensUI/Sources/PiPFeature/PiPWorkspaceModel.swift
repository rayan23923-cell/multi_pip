import AVFoundation
import Foundation
import Observation
import SwiftUI
import TLCoreServices
import TLDomain
import TLFoundation
import TLLocalization

/// The Picture in Picture workspace: the cards kept in view, which one is
/// shown, and the system window's state.
///
/// One instance lives as long as the app, so the window keeps working while
/// the user moves between screens.
@MainActor
@Observable
public final class PiPWorkspaceModel {
    public enum Status: Equatable, Sendable {
        /// This device has no Picture in Picture.
        case unsupported
        case idle
        case starting
        case active
        case stopping
    }

    public private(set) var status: Status
    public private(set) var cards: [PiPCard] = []
    public private(set) var currentCardID: PiPCardID?
    /// Why the window last closed, shown once on this screen.
    public private(set) var lastStop: PiPPresentation.StopReason?
    /// iOS reports whether the window can open right now (for example, not
    /// while another app's video is in Picture in Picture).
    public private(set) var isPossible = false
    public private(set) var hasLoaded = false
    public var errorMessage: String?

    /// Opens what a card came from when the user taps the window (Restore).
    @ObservationIgnored public var onRestore: ((PiPCard) -> Void)?
    /// How frames are drawn; follows the app's appearance and language.
    @ObservationIgnored public var appearance = PiPFrameRenderer.Appearance()

    public let engine: any PictureInPictureEngine
    private let service: PiPWorkspaceService
    private let clock: any DateProviding
    private let makeFrame: @MainActor (PiPCard?, Int, Int, PiPFrameRenderer.Appearance) -> CMSampleBuffer?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var interrupted = false
    @ObservationIgnored private var interruptionObserver: (any NSObjectProtocol)?

    public init(
        service: PiPWorkspaceService,
        engine: any PictureInPictureEngine,
        clock: any DateProviding = SystemDateProvider(),
        makeFrame: (@MainActor (PiPCard?, Int, Int, PiPFrameRenderer.Appearance) -> CMSampleBuffer?)? = nil
    ) {
        self.service = service
        self.engine = engine
        self.clock = clock
        self.makeFrame = makeFrame ?? { card, position, count, appearance in
            PiPFrameRenderer().sampleBuffer(for: card, position: position, count: count, appearance: appearance)
        }
        status = engine.isSupported ? .idle : .unsupported
        isPossible = engine.isPossible
        engine.onEvent = { [weak self] event in self?.handle(event) }
        // A call or another app's audio. iOS may close the window; when it
        // does, the stop is recorded as an interruption.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] notification in
            let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            Task { @MainActor [weak self] in self?.interruption(began: began) }
        }
    }

    public var isSupported: Bool { status != .unsupported }
    public var isActive: Bool { status == .active }
    public var canStart: Bool { status == .idle && isPossible && !cards.isEmpty }

    public var currentCard: PiPCard? {
        cards.first { $0.id == currentCardID } ?? cards.first
    }

    public var currentIndex: Int {
        currentCard.flatMap { card in cards.firstIndex { $0.id == card.id } } ?? 0
    }

    // MARK: Loading

    /// Loads the cards. `afterLaunch` notes when the window was closed with the app.
    public func load(afterLaunch: Bool = false) async {
        do {
            if afterLaunch, try await service.reconcileAfterLaunch().stopReason == .appClosed {
                lastStop = .appClosed
            }
            cards = try await service.cards()
            currentCardID = try await service.currentCard()?.id
            showCurrent()
        } catch {
            errorMessage = L10n.message(for: error)
        }
        hasLoaded = true
    }

    // MARK: Cards

    /// Adds content and shows it, in the window too when it is open.
    public func keep(_ card: PiPCard) async {
        do {
            let kept = try await service.keep(card)
            cards = try await service.cards()
            currentCardID = kept.id
            showCurrent()
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    public func keep(_ output: ToolOutput, workspaceID: WorkspaceID?) async {
        guard let card = PiPCardBuilder.card(from: output, workspaceID: workspaceID, at: clock.now()) else { return }
        await keep(card)
    }

    public func keep(_ item: ContextItem) async {
        guard let card = PiPCardBuilder.card(from: item, at: clock.now()) else { return }
        await keep(card)
    }

    public func select(_ card: PiPCard) async {
        do {
            currentCardID = try await service.select(card.id).id
            showCurrent()
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    public func step(by offset: Int) async {
        do {
            currentCardID = try await service.step(by: offset)?.id
            showCurrent()
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    public func remove(_ card: PiPCard) async {
        do {
            try await service.remove(card.id)
            cards = try await service.cards()
            currentCardID = try await service.currentCard()?.id
            showCurrent()
            if cards.isEmpty, isActive { stop() }
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    // MARK: Window

    public func start() {
        guard canStart else { return }
        lastStop = nil
        stopRequested = false
        interrupted = false
        status = .starting
        showCurrent()
        engine.start()
    }

    public func stop() {
        guard status == .active || status == .starting else { return }
        stopRequested = true
        status = .stopping
        engine.stop()
    }

    /// While the preview is on screen, leaving TaskLens opens the window by itself.
    public func setPreviewVisible(_ visible: Bool) {
        engine.setStartsAutomatically(visible && !cards.isEmpty && isSupported)
    }

    /// Redraws the shown card, for example after the appearance changed.
    public func showCurrent() {
        guard isSupported, let frame = makeFrame(currentCard, currentIndex, cards.count, appearance) else { return }
        engine.display(frame)
    }

    func handle(_ event: PiPEngineEvent) {
        switch event {
        case .possibleChanged(let possible):
            isPossible = possible
        case .didStart:
            status = .active
            record { try await $0.markStarted() }
        case .failedToStart:
            status = isSupported ? .idle : .unsupported
            lastStop = .failed
            record { try await $0.markStopped(.failed) }
        case .restoreRequested:
            if let card = currentCard { onRestore?(card) }
        case .didStop(let restored):
            status = isSupported ? .idle : .unsupported
            let reason: PiPPresentation.StopReason = restored ? .restored : (interrupted && !stopRequested ? .interrupted : .user)
            lastStop = reason == .restored ? nil : reason
            stopRequested = false
            interrupted = false
            record { try await $0.markStopped(reason) }
        case .skip(let direction):
            Task { await step(by: direction) }
        case .needsFrame:
            showCurrent()
        }
    }

    /// Records run in order: "started" must never land after "stopped".
    @ObservationIgnored private var lastRecord: Task<Void, Never>?

    private func record(_ change: @escaping @Sendable (PiPWorkspaceService) async throws -> PiPPresentation) {
        let service = service
        let previous = lastRecord
        lastRecord = Task {
            await previous?.value
            do {
                _ = try await change(service)
            } catch {
                errorMessage = L10n.message(for: error)
            }
        }
    }

    private func interruption(began: Bool) {
        if began {
            interrupted = true
        } else {
            showCurrent()
        }
    }
}

import Foundation
import Observation
import TLCoreServices
import TLDomain
import TLLocalization

@MainActor
@Observable
public final class SessionDetailModel {
    public let sessionID: SessionID
    public private(set) var session: Session?
    public private(set) var items: [ContextItem] = []
    public private(set) var hasLoaded = false
    public private(set) var isSaving = false
    public var draft = ""
    public var errorMessage: String?

    private let sessionService: SessionService
    private let captureService: CaptureService

    public init(sessionID: SessionID, sessionService: SessionService, captureService: CaptureService) {
        self.sessionID = sessionID
        self.sessionService = sessionService
        self.captureService = captureService
    }

    public var canCapture: Bool { session.map { !$0.isEnded } ?? false }

    public func load() async {
        do {
            session = try await sessionService.session(id: sessionID)
            items = try await captureService.items(in: sessionID)
        } catch {
            errorMessage = L10n.message(for: error)
        }
        hasLoaded = true
    }

    /// Saves the draft text into this session.
    public func captureDraft() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await captureService.capture(.text(draft), source: .manualEntry, into: sessionID)
            draft = ""
            await load()
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    public func pause() async {
        await transition { try await $0.pause(self.sessionID) }
    }

    public func resume() async {
        await transition { try await $0.resume(self.sessionID) }
    }

    public func end() async {
        await transition { try await $0.end(self.sessionID) }
    }

    private func transition(_ change: (SessionService) async throws -> Session) async {
        do {
            session = try await change(sessionService)
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }
}

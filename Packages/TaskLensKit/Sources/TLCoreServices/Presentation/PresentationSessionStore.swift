import Foundation
import TLDomain
import TLFoundation

/// Saves and restores where each presentation was left.
///
/// One record per presentation, keyed by its source, so presentations never
/// overwrite each other. It stores presentation state only and knows nothing
/// about rendering, and it never touches a document's `lastReadPage`.
public struct PresentationSessionStore: Sendable {
    private let sessions: any Repository<PresentationSession>
    private let clock: any DateProviding

    public init(sessions: any Repository<PresentationSession>, clock: any DateProviding = SystemDateProvider()) {
        self.sessions = sessions
        self.clock = clock
    }

    /// The saved state, or nil when there is none or it can't be read.
    public func session(for source: PresentationSessionSource) async -> PresentationSession? {
        try? await sessions.fetch(id: source.sessionID)
    }

    @discardableResult
    public func save(
        _ source: PresentationSessionSource,
        currentSlide: Int,
        slideCount: Int,
        autoPlayInterval: Int?
    ) async throws -> PresentationSession {
        let session = PresentationSession(
            source: source,
            currentSlide: currentSlide,
            slideCount: slideCount,
            autoPlayInterval: autoPlayInterval,
            lastViewedAt: clock.now()
        )
        try await sessions.upsert(session)
        return session
    }

    /// Forgets a presentation, for example when its document no longer opens.
    public func remove(_ source: PresentationSessionSource) async throws {
        try await sessions.delete(id: source.sessionID)
    }

    public func allSessions() async throws -> [PresentationSession] {
        try await sessions.fetchAll()
    }
}

/// Writes one presentation's state as it changes, in order and without piling up.
///
/// Each change replaces the pending one; a single writer saves the newest state
/// and then any newer one that arrived meanwhile. A burst of slide changes (or
/// Auto Play) costs at most one write in flight plus one after it, and an older
/// state can never be written after a newer one. Unchanged state is not written.
@MainActor
public final class PresentationSessionRecorder {
    public struct Snapshot: Equatable, Sendable {
        public var currentSlide: Int
        public var slideCount: Int
        public var autoPlayInterval: Int?

        public init(currentSlide: Int, slideCount: Int, autoPlayInterval: Int?) {
            self.currentSlide = currentSlide
            self.slideCount = slideCount
            self.autoPlayInterval = autoPlayInterval
        }
    }

    public let source: PresentationSessionSource
    private let store: PresentationSessionStore
    private var pending: Snapshot?
    private var lastWritten: Snapshot?
    private var writer: Task<Void, Never>?
    /// Writes made, for tests and diagnostics.
    public private(set) var writeCount = 0

    public init(source: PresentationSessionSource, store: PresentationSessionStore) {
        self.source = source
        self.store = store
    }

    /// Marks `snapshot` as already stored, so restoring doesn't write it back.
    public func markStored(_ snapshot: Snapshot) {
        lastWritten = snapshot
    }

    public func record(_ snapshot: Snapshot) {
        guard snapshot != lastWritten || writer != nil else { return }
        pending = snapshot
        guard writer == nil else { return }
        writer = Task { await drain() }
    }

    /// Waits until everything recorded so far is stored.
    public func flush() async {
        while let writer { await writer.value }
    }

    private func drain() async {
        while let next = pending {
            pending = nil
            guard next != lastWritten else { continue }
            do {
                try await store.save(
                    source,
                    currentSlide: next.currentSlide,
                    slideCount: next.slideCount,
                    autoPlayInterval: next.autoPlayInterval
                )
                lastWritten = next
                writeCount += 1
            } catch {
                // Keeping the old saved slide is harmless; the next change tries again.
            }
        }
        writer = nil
    }
}

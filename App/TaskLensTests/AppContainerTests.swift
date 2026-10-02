import Foundation
import Testing
import TLData
import TLDomain
@testable import TaskLens

@Suite("App composition")
struct AppContainerTests {
    @Test func previewContainerWiresServicesEndToEnd() async throws {
        let container = AppContainer.preview()
        let workspace = try await container.workspaces.create(name: "Trip")
        let session = try await container.sessions.start(in: workspace.id, kind: .shopping)
        let item = try await container.capture.capture(.text("$125"), source: .manualEntry, into: session.id)
        let entry = try await container.clipboard.record(.text("0770 123 4567"))
        let promoted = try await container.clipboard.promote(entry.id, to: session.id)

        #expect(try await container.capture.items(in: session.id).map(\.id).contains(item.id))
        #expect(promoted.source == .clipboard)
        #expect(container.storage == .memory)
    }

    @Test func liveContainerOpensPersistentStore() {
        // In unsigned simulator builds the App Group is unavailable, so the
        // store falls back to local Application Support. Either is persistent.
        let container = AppContainer.live()
        #expect(container.storage != .memory)
    }

    @Test func appVersionIsReadable() {
        #expect(!AppContainer.appVersion.isEmpty)
    }
}

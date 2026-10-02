import Foundation
import Testing
@testable import TLFoundation

private enum Tag {}

@Suite("Identifier")
struct IdentifierTests {
    @Test func encodesAsBareUUIDString() throws {
        let uuid = UUID()
        let id = Identifier<Tag>(uuid)
        let data = try JSONEncoder().encode([id])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == "[\"\(uuid.uuidString)\"]")
        let decoded = try JSONDecoder().decode([Identifier<Tag>].self, from: data)
        #expect(decoded == [id])
    }

    @Test func parsesUUIDStrings() {
        #expect(Identifier<Tag>(uuidString: "not-a-uuid") == nil)
        let uuid = UUID()
        #expect(Identifier<Tag>(uuidString: uuid.uuidString)?.rawValue == uuid)
    }

    @Test func newIdentifiersAreUnique() {
        #expect(Identifier<Tag>() != Identifier<Tag>())
    }
}

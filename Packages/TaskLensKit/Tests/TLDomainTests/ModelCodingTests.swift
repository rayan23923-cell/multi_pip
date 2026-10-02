import Foundation
import Testing
@testable import TLDomain
import TLFoundation

@Suite("Domain model coding")
struct ModelCodingTests {
    @Test func workspaceRoundTrips() throws {
        let workspace = Workspace(
            name: "Trip",
            symbolName: "airplane",
            color: .orange,
            createdAt: Fixtures.date,
            metadata: ["origin": "test"]
        )
        #expect(try Fixtures.roundTrip(workspace) == workspace)
        #expect(workspace.updatedAt == workspace.createdAt)
    }

    @Test func sessionRoundTripsWithState() throws {
        var session = Session(workspaceID: WorkspaceID(), title: "Research", kind: .research, startedAt: Fixtures.date)
        try session.end(at: Fixtures.date.addingTimeInterval(60))
        let decoded = try Fixtures.roundTrip(session)
        #expect(decoded == session)
        #expect(decoded.state == .ended)
        #expect(decoded.endedAt == Fixtures.date.addingTimeInterval(60))
    }

    @Test func contextItemRoundTripsWithEntities() throws {
        let entity = DetectedEntity(
            type: .currencyAmount,
            confidence: .high,
            value: .currency(amount: Decimal(string: "125.5")!, currencyCode: "USD"),
            matchedText: "$125.50",
            range: TextRange(location: 6, length: 7)
        )
        let item = ContextItem(
            sessionID: SessionID(),
            source: .clipboard,
            content: .text("Total $125.50"),
            entities: [entity],
            metadata: ["app": "Safari"],
            createdAt: Fixtures.date
        )
        let decoded = try Fixtures.roundTrip(item)
        #expect(decoded == item)
        #expect(decoded.type == .text)
    }

    @Test func everyEntityValueRoundTrips() throws {
        let values: [EntityValue] = [
            .text("hello"),
            .url(URL(string: "https://example.com/a?b=c")!),
            .phoneNumber("+9647701234567"),
            .email("a@example.com"),
            .date(Fixtures.date),
            .currency(amount: 10, currencyCode: nil),
            .number(Decimal(string: "3.5")!),
            .address(["city": "Baghdad", "country": "IQ"]),
        ]
        #expect(try Fixtures.roundTrip(values) == values)
    }

    @Test func documentNoteClipboardRoundTrip() throws {
        let file = FileReference(
            relativePath: "Files/a.pdf",
            originalFilename: "a.pdf",
            contentType: "com.adobe.pdf",
            kind: .pdf,
            byteCount: 1024
        )
        let document = Document(title: "Spec", file: file, pageCount: 3, lastReadPage: 1, createdAt: Fixtures.date)
        let note = Note(title: "Idea", body: "Body", isPinned: true, createdAt: Fixtures.date)
        let clip = ClipboardItem(content: .url(URL(string: "https://apple.com")!), offeredTypes: ["public.url"], capturedAt: Fixtures.date)

        #expect(try Fixtures.roundTrip(document) == document)
        #expect(try Fixtures.roundTrip(note) == note)
        #expect(try Fixtures.roundTrip(clip) == clip)
        #expect(document.kind == .pdf)
    }

    @Test func unknownKindsSurviveDecoding() throws {
        // A newer app version may write kinds this build does not know about.
        let json = Data(#"["future-kind","research"]"#.utf8)
        let kinds = try JSONDecoder().decode([SessionKind].self, from: json)
        #expect(kinds == [SessionKind(rawValue: "future-kind"), .research])
        #expect(try Fixtures.roundTrip(kinds) == kinds)
    }

    @Test func extensibleKindsEncodeAsPlainStrings() throws {
        let data = try JSONEncoder().encode([ActionType.call])
        #expect(String(decoding: data, as: UTF8.self) == #"["call"]"#)
    }
}

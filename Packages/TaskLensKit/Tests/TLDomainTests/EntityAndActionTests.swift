import Foundation
import Testing
@testable import TLDomain
import TLFoundation

@Suite("Entities and actions")
struct EntityAndActionTests {
    @Test(arguments: [(-1.0, 0.0), (0.42, 0.42), (2.0, 1.0), (Double.nan, 0.0)])
    func confidenceIsClamped(input: Double, expected: Double) {
        #expect(Confidence(input).value == expected)
    }

    @Test func decodedConfidenceIsClamped() throws {
        let decoded = try JSONDecoder().decode([Confidence].self, from: Data("[5]".utf8))
        #expect(decoded == [Confidence(1)])
    }

    @Test func contentTypeIsDerivedFromContent() {
        let pdf = FileReference(relativePath: "a.pdf", contentType: "com.adobe.pdf", kind: .pdf)
        let image = FileReference(relativePath: "a.png", contentType: "public.png", kind: .image)
        #expect(ContextContent.text("x").itemType == .text)
        #expect(ContextContent.url(URL(string: "https://a.b")!).itemType == .url)
        #expect(ContextContent.file(pdf).itemType == .pdf)
        #expect(ContextContent.file(image).itemType == .image)
    }

    @Test func logDescriptionNeverContainsContent() {
        let secret = "my secret phone 0770 123 4567"
        #expect(!ContextContent.text(secret).logDescription.contains("secret"))
        #expect(!ContextContent.url(URL(string: "https://bank.example/secret")!).logDescription.contains("secret"))
    }

    @Test func rankedEntitiesPutHighestConfidenceFirst() {
        let low = DetectedEntity(type: .number, confidence: .low, value: .number(1))
        let high = DetectedEntity(type: .phoneNumber, confidence: .high, value: .phoneNumber("1"))
        let item = ContextItem(source: .manualEntry, content: .text("x"), entities: [low, high], createdAt: Fixtures.date)
        #expect(item.rankedEntities.map(\.id) == [high.id, low.id])
    }

    @Test func actionsRankByPriorityThenType() {
        let copy = Action(type: .copy, priority: .normal)
        let call = Action(type: .call, priority: .primary)
        let share = Action(type: .share, priority: .normal)
        #expect(Action.ranked([share, copy, call]).map(\.type) == [.call, .copy, .share])
    }

    @Test func actionTitleDefaultsToLocalizationKey() {
        #expect(Action(type: .openURL).titleKey == "action.openURL")
        #expect(Action(type: .openURL, titleKey: "custom").titleKey == "custom")
    }

    @Test func actionResultSuccessFlag() {
        let id = ActionID()
        #expect(ActionResult(actionID: id, actionType: .copy, outcome: .succeeded(output: nil), completedAt: Fixtures.date).isSuccess)
        #expect(ActionResult(actionID: id, actionType: .call, outcome: .handedOff, completedAt: Fixtures.date).isSuccess)
        #expect(!ActionResult(actionID: id, actionType: .call, outcome: .cancelled, completedAt: Fixtures.date).isSuccess)
        #expect(!ActionResult(
            actionID: id,
            actionType: .call,
            outcome: .failed(.unavailable(feature: "x")),
            completedAt: Fixtures.date
        ).isSuccess)
    }

    @Test func emptyNoteDetection() {
        #expect(Note(title: "  ", body: "\n", createdAt: Fixtures.date).isEmpty)
        #expect(!Note(body: "x", createdAt: Fixtures.date).isEmpty)
    }
}

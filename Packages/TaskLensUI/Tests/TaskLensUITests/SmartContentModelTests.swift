import ClipboardFeature
import Foundation
import ShareFeature
import Testing
import TLActionsUI
import TLCoreServices
import TLData
import TLDomain
import TLFoundation
import UniformTypeIdentifiers

@Suite("Action plans")
struct ActionPlanTests {
    private func plan(_ text: String, _ type: ActionType, capabilities: ActionCapabilities = .app) -> ActionPlan? {
        let content = ContextContent.text(text)
        guard let action = RuleActionEngine.analyze(content).actions.first(where: { $0.type == type }) else { return nil }
        return ActionPlan.make(for: action, content: content, capabilities: capabilities)
    }

    @Test func phoneActionsOpenSystemApps() {
        #expect(plan("+964 770 123 4567", .call) == .open(URL(string: "tel:+9647701234567")!))
        #expect(plan("٠٧٧٠ ١٢٣ ٤٥٦٧", .sendMessage) == .open(URL(string: "sms:07701234567")!))
        #expect(plan("+964 770 123 4567", .saveToSession) == .save)
        #expect(plan("+964 770 123 4567", .copy) == .copy("+964 770 123 4567"))
    }

    @Test func linksEmailsAndAddresses() {
        #expect(plan("https://example.com/a", .openURL) == .open(URL(string: "https://example.com/a")!))
        #expect(plan("https://example.com/a", .share) == .share("https://example.com/a"))
        #expect(plan("name@example.com", .sendEmail) == .open(URL(string: "mailto:name@example.com")!))
    }

    @Test func numbersAndMoney() {
        #expect(plan("1,250.5", .calculate) == .calculate(Decimal(string: "1250.5")!))
        #expect(plan("$25.99", .calculate) == .calculate(Decimal(string: "25.99")!))
        #expect(plan("$25.99", .convertCurrency) == .comingLater)
    }

    @Test func textAndDatePlaceholdersAreHonest() {
        let text = "Meet the design team about the new layout"
        #expect(plan(text, .translate) == .translate(text))
        #expect(plan(text, .summarize) == .comingLater)
        #expect(plan("2026-10-15", .createReminder) == .comingLater)
        #expect(plan("2026-10-15", .addToCalendar) == .comingLater)
    }

    @Test func shareExtensionPointsToTheApp() {
        let ext = ActionCapabilities.shareExtension
        #expect(plan("+964 770 123 4567", .call, capabilities: ext) == .openApp)
        #expect(plan("https://example.com", .openURL, capabilities: ext) == .openApp)
        #expect(plan("42", .calculate, capabilities: ext) == .openApp)
        #expect(plan("https://example.com", .copy, capabilities: ext) == .copy("https://example.com"))
    }

    @Test func unsafeOrMissingValuesAreUnavailable() {
        let javascript = Action(type: .openURL, parameters: [Action.ParameterKey.value: .string("javascript:alert(1)")])
        #expect(ActionPlan.make(for: javascript, content: nil) == .unavailable)
        #expect(ActionPlan.make(for: Action(type: .call), content: nil) == .unavailable)
        #expect(ActionPlan.make(for: Action(type: "future"), content: .text("x")) == .unavailable)
    }
}

@MainActor
final class FakePasteboardProbe: PasteboardProbing {
    var changeCount = 1
    var hasContent = false
}

@MainActor
@Suite("Smart Clipboard model")
struct SmartClipboardModelTests {
    private func makeDefaults() -> UserDefaults {
        let name = "SmartClipboardTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func pastedEntriesAreAnalyzedAndSelected() async throws {
        let services = Services()
        let model = ClipboardModel(clipboardService: services.clipboard, sessionService: services.sessions,
                                   probe: FakePasteboardProbe(), defaults: makeDefaults())
        await model.paste(["+964 770 123 4567"])
        let entry = try #require(model.selectedItem)
        let analysis = model.analysis(for: entry)
        #expect(analysis.category == .phone)
        #expect(analysis.actions.map(\.type).prefix(3) == [.call, .sendMessage, .saveToSession])

        await model.paste(["one", "two"])
        #expect(model.history.count == 3)
        #expect(model.history.map { model.analysis(for: $0).category }.contains(.plainText))
    }

    @Test func hintShowsOnlyForNewContentWithoutReadingIt() async {
        let services = Services()
        let probe = FakePasteboardProbe()
        let model = ClipboardModel(clipboardService: services.clipboard, sessionService: services.sessions,
                                   probe: probe, defaults: makeDefaults())
        model.refreshPasteboardHint()
        #expect(!model.hasNewContent, "Nothing on the pasteboard")

        probe.hasContent = true
        model.refreshPasteboardHint()
        #expect(model.hasNewContent)

        await model.paste(["copied"])
        model.refreshPasteboardHint()
        #expect(!model.hasNewContent, "Already pasted")

        probe.changeCount = 2
        model.refreshPasteboardHint()
        #expect(model.hasNewContent)
        model.dismissPasteboardHint()
        #expect(!model.hasNewContent)
    }
}

@MainActor
@Suite("Share sheet model")
struct ShareModelTests {
    private func makeModel(_ providers: [NSItemProvider], services: Services, root: URL) -> ShareModel {
        ShareModel(
            providers: providers,
            workingDirectory: root.appendingPathComponent("intake"),
            outbox: ShareOutbox(storeRoot: root),
            sessionService: services.sessions,
            confirmationDelay: .zero
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ShareModelTests-\(UUID().uuidString)")
    }

    @Test func loadsMultipleItemsAndSavesToTheOutbox() async throws {
        let services = Services()
        let workspace = try await services.workspaces.create(name: "Trip")
        let session = try await services.sessions.start(in: workspace.id)
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = makeModel([
            NSItemProvider(object: "+964 770 123 4567" as NSString),
            NSItemProvider(object: URL(string: "https://example.com")! as NSURL),
            NSItemProvider(item: Data([1]) as NSData, typeIdentifier: "com.example.unknown-thing"),
        ], services: services, root: root)
        var outcome: ShareModel.Outcome?
        model.onFinish = { outcome = $0 }

        model.start()
        await model.waitUntilLoaded()
        #expect(model.phase == .ready)
        #expect(model.previews.map(\.analysis.category) == [.phone, .url, .unknown])
        #expect(model.supportedCount == 2)
        #expect(model.selectedSessionID == session.id)

        await model.save()
        #expect(outcome == .saved(count: 2))
        #expect(model.phase == .saved(count: 2))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("intake").path))
        #expect(ShareOutbox(storeRoot: root).pendingEnvelopes().count == 1)
    }

    @Test func nothingSupportedCannotBeSaved() async {
        let services = Services()
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel([NSItemProvider(item: Data([1]) as NSData, typeIdentifier: "com.example.unknown-thing")],
                              services: services, root: root)
        model.start()
        await model.waitUntilLoaded()
        #expect(model.phase == .ready)
        #expect(!model.canSave)
        await model.save()
        #expect(ShareOutbox(storeRoot: root).pendingEnvelopes().isEmpty)
    }

    @Test func cancelFinishesOnceAndCleansUp() async {
        let services = Services()
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel([NSItemProvider(object: "hello" as NSString)], services: services, root: root)
        var outcomes: [ShareModel.Outcome] = []
        model.onFinish = { outcomes.append($0) }

        model.start()
        model.cancel()
        model.cancel()
        await model.waitUntilLoaded()
        #expect(outcomes == [.cancelled])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("intake").path))
        #expect(ShareOutbox(storeRoot: root).pendingEnvelopes().isEmpty)
    }

    @Test func noItemsAndNoStoreStillWork() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ShareModel(providers: [], workingDirectory: root.appendingPathComponent("intake"),
                               outbox: ShareOutbox(storeRoot: root), sessionService: nil, confirmationDelay: .zero)
        model.start()
        await model.waitUntilLoaded()
        #expect(model.phase == .ready)
        #expect(model.previews.isEmpty)
        #expect(model.sessions.isEmpty)
        #expect(!model.canSave)
    }
}

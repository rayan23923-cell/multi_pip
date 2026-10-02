import Foundation
import Testing
import TLCoreServices
import TLDomain
import TLFoundation

private let english = ActionContext(source: .manualEntry, preferredLanguage: "en")

private func analyze(_ text: String, context: ActionContext = english) -> ContextAnalysis {
    ActionEngine.analyze(.text(text), context: context)
}

private extension Array where Element == Action {
    var types: [ActionType] { map(\.type) }
}

/// A fixed history for ranking tests.
private struct FixedHistory: ActionHistoryProviding {
    let preferred: ActionType
    func preference(for type: ActionType, category: ContentCategory) -> Double { type == preferred ? 1 : 0 }
}

@Suite("Action generator")
struct ActionGeneratorTests {
    @Test func moneyMatchesTheDesign() {
        // $125 → Recommended: Convert, Calculate, Save. More: Copy, Share.
        let suggestions = analyze("$125").suggestions
        #expect(suggestions.primary.types == [.convertCurrency, .calculate, .saveToSession])
        #expect(suggestions.secondary.isEmpty)
        #expect(suggestions.more.types == [.copy, .share])
        let convert = suggestions.primary[0]
        #expect(convert.isPlaceholder)
        #expect(convert.parameters[Action.ParameterKey.currencyCode] == .string("USD"))
        #expect(suggestions.primary[1].valueText == "125")
    }

    @Test func phone() {
        let analysis = analyze("+964 770 123 4567")
        #expect(analysis.suggestions.primary.types == [.call, .sendMessage, .saveToSession])
        let call = analysis.actions[0]
        #expect(call.requiresConfirmation)
        #expect(call.valueText == "+9647701234567")
        #expect(call.targetEntityID == analysis.primaryEntity?.id)
    }

    @Test func linkEmailAddressNumber() {
        #expect(analyze("https://example.com").suggestions.primary.types == [.openURL, .saveToSession, .search])
        #expect(analyze("hello@example.com").actions.first?.type == .sendEmail)
        #expect(analyze("1 Apple Park Way, Cupertino, CA 95014").actions.first?.type == .openInMaps)
        #expect(analyze("1,250").actions.first?.type == .calculate)
        #expect(analyze("1,250").actions.first?.valueText == "1250")
    }

    @Test func dateCreatesEventsAndReminders() {
        let analysis = analyze("2026-10-15")
        #expect(analysis.suggestions.primary.types == [.addToCalendar, .createReminder, .saveToSession])
        let event = analysis.actions[0]
        #expect(!event.isPlaceholder)
        #expect(event.valueText == "2026-10-15")
        #expect(event.parameters[Action.ParameterKey.includesTime] == .bool(false))
        #expect(analysis.actions[1].isPlaceholder)
    }

    @Test func textInTheUsersLanguage() {
        let suggestions = analyze("Meeting notes for the team").suggestions
        #expect(suggestions.primary.types == [.saveToSession, .copy, .createNote])
        #expect(suggestions.secondary.types == [.translate, .search])
        #expect(suggestions.more.types == [.share, .summarize, .askAI])
        #expect(suggestions.more.filter(\.isPlaceholder).types == [.summarize, .askAI])
    }

    @Test func entitiesInsideTextGetTheirOwnActions() throws {
        let analysis = analyze("Call +1 415 555 0132 or write to team@example.com")
        #expect(analysis.category == .plainText)
        let call = try #require(analysis.actions.first { $0.type == .call })
        #expect(call.valueText == "+14155550132")
        #expect(call.targetEntityID == analysis.entities.first { $0.type == .phoneNumber }?.id)
        #expect(analysis.actions.contains { $0.type == .sendEmail })
        // Two useful parts: Extract lists them.
        let extract = try #require(analysis.actions.first { $0.type == .extractText })
        #expect(extract.parameters[Action.ParameterKey.values] == .array([.string("+14155550132"), .string("team@example.com")]))
        // An entity action inside text ranks below the same action on content that is the entity.
        let wholeCall = try #require(analyze("+1 415 555 0132").actions.first { $0.type == .call })
        #expect(call.priority < wholeCall.priority)
    }

    @Test func eventTitleComesFromTheSentence() throws {
        let analysis = analyze("Dentist appointment on October 20, 2026 at 3:00 PM")
        let event = try #require(analysis.actions.first { $0.type == .addToCalendar })
        #expect(event.parameters[Action.ParameterKey.title]?.stringValue?.hasPrefix("Dentist appointment") == true)
        #expect(event.parameters[Action.ParameterKey.includesTime] == .bool(true))
    }

    @Test func filesAndUnknown() {
        let pdf = ContextContent.file(FileReference(relativePath: "a.pdf", contentType: "com.adobe.pdf", kind: .pdf))
        let actions = ActionEngine.analyze(pdf, context: english).actions
        #expect(actions.first?.type == .saveToSession)
        #expect(actions.first { $0.type == .extractText }?.isPlaceholder == true)
        #expect(analyze("   ").actions.first?.type == .saveToSession)
    }

    @Test func everyCategoryCanBeSavedAndNoTypeRepeats() {
        for text in ["x y z", "42", "a@b.co", "{\"a\":1}", "   ", "$5", "2026-10-15", "https://a.com",
                     "Call +1 415 555 0132 or visit https://a.com on October 20, 2026"] {
            let types = analyze(text).actions.types
            #expect(types.contains(.saveToSession), "\(text)")
            #expect(Set(types).count == types.count, "\(text) repeats an action")
        }
    }

    @Test func storedItemsUseTheirSource() async throws {
        let env = TestEnvironment()
        let item = try await env.capture.capture(.text("42"), source: .manualEntry)
        let actions = await ActionEngine(context: english).suggestActions(for: item)
        #expect(actions.first?.type == .calculate)
        #expect(actions.allSatisfy { $0.targetItemID == item.id })

        // The same number coming from the calculator is not sent back to it first.
        // (Different text: capturing "42" again would return the first item as a duplicate.)
        let fromCalculator = try await env.capture.capture(.text("43"), source: .calculator)
        #expect(await ActionEngine(context: english).suggestActions(for: fromCalculator).first?.type == .saveToSession)
    }
}

@Suite("Action ranking")
struct ActionRankingTests {
    @Test func sameInputSameOrder() {
        let text = "Call +1 415 555 0132 or visit https://example.com, it costs $25"
        let first = analyze(text).actions.types
        for _ in 0..<5 {
            #expect(analyze(text).actions.types == first)
        }
    }

    @Test func orderDoesNotDependOnCandidateOrder() {
        let input = Normalizer.normalize(.text("+964 770 123 4567"))
        let (category, entities) = ContextEngine.analyze(input)
        let candidates = ActionEngine.generate(category: category, entities: entities, input: input)
        let ranked = ActionEngine.rank(candidates, category: category, input: input, context: english).map(\.action.type)
        let reversed = ActionEngine.rank(candidates.reversed(), category: category, input: input, context: english).map(\.action.type)
        #expect(ranked == reversed)
    }

    @Test func scoresAreBoundedAndSorted() {
        for text in ["$125", "Meeting notes for the team", "+964 770 123 4567", "2026-10-15"] {
            let input = Normalizer.normalize(.text(text), source: .shareExtension)
            let (category, entities) = ContextEngine.analyze(input)
            let candidates = ActionEngine.generate(category: category, entities: entities, input: input)
            let ranked = ActionEngine.rank(candidates, category: category, input: input,
                                           context: ActionContext(source: .shareExtension, preferredLanguage: "en"))
            #expect(ranked.allSatisfy { (0...1).contains($0.score) })
            #expect(ranked.map(\.score) == ranked.map(\.score).sorted(by: >))
            #expect(ranked.allSatisfy { $0.action.priority.rawValue == Int(($0.score * 1000).rounded()) })
            #expect(ranked.allSatisfy { !$0.reasons.isEmpty })
        }
    }

    @Test func confidenceLowersEntityActions() {
        // A short local number is less surely a phone number than a full international one.
        let short = analyze("555-0132").actions.first { $0.type == .call }!
        let full = analyze("+964 770 123 4567").actions.first { $0.type == .call }!
        #expect(short.priority < full.priority)
        // Generic actions do not depend on confidence.
        #expect(analyze("555-0132").actions.first { $0.type == .saveToSession }?.priority
                == analyze("+964 770 123 4567").actions.first { $0.type == .saveToSession }?.priority)
    }

    @Test func clipboardSourceLowersCopy() {
        let manual = analyze("Meeting notes for the team").actions.types
        let clipboard = analyze("Meeting notes for the team", context: ActionContext(source: .clipboard, preferredLanguage: "en")).actions.types
        #expect(manual.firstIndex(of: .copy)! < clipboard.firstIndex(of: .copy)!)
    }

    @Test func shareExtensionPrefersSavingOverLeavingTheSheet() {
        let context = ActionContext(source: .shareExtension, preferredLanguage: "en")
        let actions = analyze("+964 770 123 4567", context: context).actions.types
        #expect(actions.first == .saveToSession)
        #expect(actions.last == .share)
    }

    @Test func translateDependsOnTheUsersLanguage() {
        let arabicUser = ActionContext(source: .manualEntry, preferredLanguage: "ar")
        #expect(analyze("Meeting notes for the team", context: arabicUser).suggestions.primary.first?.type == .translate)
        #expect(analyze("ملاحظات الاجتماع مع الفريق", context: english).suggestions.primary.first?.type == .translate)
        #expect(!analyze("ملاحظات الاجتماع مع الفريق", context: arabicUser).suggestions.primary.types.contains(.translate))
    }

    @Test func longTextFavorsNotesAndSummaries() {
        let long = String(repeating: "The quarterly review covers budget, hiring and the roadmap. ", count: 8)
        let short = analyze("The quarterly review covers budget").actions
        let longActions = analyze(long).actions
        let summarize = { (actions: [Action]) in actions.first { $0.type == .summarize }!.priority }
        #expect(summarize(longActions) > summarize(short))
    }

    @Test func historyCanPromoteAnAction() {
        let context = ActionContext(source: .manualEntry, preferredLanguage: "en", history: FixedHistory(preferred: .share))
        #expect(analyze("https://example.com").suggestions.primary.types == [.openURL, .saveToSession, .search])
        #expect(analyze("https://example.com", context: context).suggestions.primary.types == [.openURL, .share, .saveToSession])
        #expect(NoActionHistory().preference(for: .copy, category: .plainText) == 0)
    }

    @Test func placeholdersRankBelowEqualWorkingActions() {
        let input = Normalizer.normalize(.text("hello world"))
        let working = ActionCandidate(type: .copy, relevance: 0.6, entity: nil, isSpecific: false, isPlaceholder: false,
                                      requiresConfirmation: false, parameters: [:], order: 1)
        var placeholder = working
        placeholder.type = .summarize
        placeholder.isPlaceholder = true
        placeholder.order = 0
        let ranked = ActionEngine.rank([placeholder, working], category: .plainText, input: input, context: english)
        #expect(ranked.map(\.action.type) == [.copy, .summarize])
    }

    @Test func tiersNeverShowAWallOfButtons() {
        func action(_ type: ActionType, _ score: Int) -> Action { Action(type: type, priority: ActionPriority(score)) }
        let many = (0..<12).map { action(ActionType(rawValue: "a\($0)"), 950 - $0 * 10) }
        let tiers = ActionSuggestions(ranked: many)
        #expect(tiers.primary.count == ActionSuggestions.primaryLimit)
        #expect(tiers.secondary.count == ActionSuggestions.secondaryLimit)
        #expect(tiers.all == many)

        // Weak actions are not recommended, but there is always one recommendation.
        let weak = ActionSuggestions(ranked: [action(.saveToSession, 300), action(.copy, 200)])
        #expect(weak.primary.types == [.saveToSession])
        #expect(weak.secondary.isEmpty)
        #expect(weak.more.types == [.copy])
        #expect(ActionSuggestions(ranked: []).isEmpty)
    }
}

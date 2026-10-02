import Foundation
import Testing
import TLDomain
import TLFoundation
@testable import TLLocalization

@Suite("Localization")
struct LocalizationTests {
    @Test(arguments: ["en", "ar"])
    func everyKeyIsTranslated(localization: String) {
        let missing = L10nKey.allCases.filter { L10n.string($0, localization: localization) == nil }
        #expect(missing.isEmpty, "Missing \(localization) strings: \(missing.map(\.rawValue))")
    }

    @Test func arabicDiffersFromEnglishForUIStrings() {
        // Catches a catalog where Arabic was accidentally filled with English.
        let english = L10n.string(.tabWorkspaces, localization: "en")
        let arabic = L10n.string(.tabWorkspaces, localization: "ar")
        #expect(english != nil)
        #expect(arabic != nil)
        #expect(english != arabic)
    }

    @Test func everyDomainErrorHasAMessage() {
        for key in TaskLensError.allLocalizationKeys {
            #expect(L10nKey(rawValue: key) != nil, "No L10nKey for \(key)")
        }
    }

    @Test func unknownErrorsUseGenericMessage() {
        struct Other: Error {}
        #expect(L10n.message(for: Other()) == L10n.string(.errorGeneric))
        #expect(L10n.message(for: TaskLensError.validationFailed(.emptyName)) == L10n.string(.errorValidationEmptyName))
    }

    @Test func formatsArabicAndEnglishCopyNames() {
        let english = L10n.string(.workspaceCopyName, localization: "en")
        let arabic = L10n.string(.workspaceCopyName, localization: "ar")
        #expect(english.map { String(format: $0, "Shop") } == "Shop Copy")
        #expect(arabic.map { String(format: $0, "متجر") } == "نسخة من متجر")
    }

    @Test func everyKnownKindAndToolHasItsOwnLabel() {
        let kindKeys = WorkspaceKind.allKnown.map(L10nKey.workspaceKind)
        let toolKeys = WorkspaceTool.allKnown.map(L10nKey.workspaceTool)
        #expect(Set(kindKeys).count == WorkspaceKind.allKnown.count)
        #expect(Set(toolKeys).count == WorkspaceTool.allKnown.count)
        #expect(!toolKeys.contains(.workspaceToolOther))
    }

    @Test func arabicIsARightToLeftLanguage() {
        #expect(Locale.Language(identifier: "ar").characterDirection == .rightToLeft)
        #expect(Locale.Language(identifier: "en").characterDirection == .leftToRight)
    }

    @Test func domainLabelsMapToKeys() {
        #expect(L10nKey.sessionKind(.research) == .sessionKindResearch)
        #expect(L10nKey.sessionKind(SessionKind(rawValue: "future")) == .sessionKindOther)
        #expect(L10nKey.sessionState(.paused) == .sessionStatePaused)
        #expect(L10nKey.itemType(.url) == .itemTypeUrl)
    }
}

import Foundation
import SwiftUI
import TLDomain
import TLFoundation

/// Access to localized strings. All user-facing text goes through `L10nKey`
/// so a missing translation is caught by tests rather than shipped.
public enum L10n {
    public static var bundle: Bundle { .module }

    public static func string(_ key: L10nKey) -> String {
        bundle.localizedString(forKey: key.rawValue, value: nil, table: nil)
    }

    /// Fills a key containing format specifiers such as `%@`.
    public static func format(_ key: L10nKey, _ arguments: any CVarArg...) -> String {
        String(format: string(key), locale: Locale.current, arguments: arguments)
    }

    /// Looks up a key in a specific localization (used by tests and previews).
    public static func string(_ key: L10nKey, localization: String) -> String? {
        guard let path = bundle.path(forResource: localization, ofType: "lproj"),
              let localized = Bundle(path: path)
        else { return nil }
        let value = localized.localizedString(forKey: key.rawValue, value: nil, table: nil)
        return value == key.rawValue ? nil : value
    }

    /// A localized, user-presentable message for any error.
    public static func message(for error: any Error) -> String {
        guard let error = error as? TaskLensError,
              let key = L10nKey(rawValue: error.localizationKey)
        else { return string(.errorGeneric) }
        return string(key)
    }
}

// MARK: - Domain labels

extension L10nKey {
    public static func sessionState(_ state: SessionState) -> L10nKey {
        switch state {
        case .active: .sessionStateActive
        case .paused: .sessionStatePaused
        case .ended: .sessionStateEnded
        }
    }

    public static func sessionKind(_ kind: SessionKind) -> L10nKey {
        switch kind {
        case .general: .sessionKindGeneral
        case .research: .sessionKindResearch
        case .shopping: .sessionKindShopping
        case .study: .sessionKindStudy
        case .developer: .sessionKindDeveloper
        default: .sessionKindOther
        }
    }

    public static func workspaceKind(_ kind: WorkspaceKind) -> L10nKey {
        switch kind {
        case .study: .workspaceKindStudy
        case .work: .workspaceKindWork
        case .shopping: .workspaceKindShopping
        case .developer: .workspaceKindDeveloper
        default: .workspaceKindCustom
        }
    }

    public static func workspaceTool(_ tool: WorkspaceTool) -> L10nKey {
        switch tool {
        case .notes: .workspaceToolNotes
        case .calculator: .workspaceToolCalculator
        case .browser: .workspaceToolBrowser
        case .documents: .workspaceToolDocuments
        case .clipboard: .workspaceToolClipboard
        case .lens: .workspaceToolLens
        default: .workspaceToolOther
        }
    }

    public static func itemType(_ type: ContextItemType) -> L10nKey {
        switch type {
        case .text: .itemTypeText
        case .url: .itemTypeUrl
        case .image: .itemTypeImage
        case .pdf: .itemTypePdf
        case .document: .itemTypeDocument
        }
    }

    public static func category(_ category: ContentCategory) -> L10nKey {
        L10nKey(rawValue: "category.\(category.rawValue)") ?? .categoryUnknown
    }

    /// Entity types are labelled with the matching content category.
    public static func entityType(_ type: EntityType) -> L10nKey {
        switch type {
        case .url: .categoryUrl
        case .email: .categoryEmail
        case .phoneNumber: .categoryPhone
        case .date: .categoryDate
        case .address: .categoryAddress
        case .currencyAmount: .categoryCurrency
        case .number: .categoryNumber
        case .json: .categoryJson
        case .code: .categoryCode
        default: .categoryUnknown
        }
    }

    /// Title of an action, if the catalog has one for its key.
    public static func action(_ action: Action) -> L10nKey? {
        L10nKey(rawValue: action.titleKey) ?? L10nKey(rawValue: action.type.defaultTitleKey)
    }
}

// MARK: - SwiftUI

extension Text {
    public init(_ key: L10nKey) {
        self.init(LocalizedStringKey(key.rawValue), bundle: L10n.bundle)
    }
}

// MARK: - Sessions

extension L10nKey {
    public static func sessionItemKind(_ kind: SessionItemKind) -> L10nKey {
        L10nKey(rawValue: "session.itemKind.\(kind.rawValue)") ?? .sessionItemKindText
    }

    public static func sessionSortOption(_ sort: SessionSort) -> L10nKey {
        L10nKey(rawValue: "session.sort.\(sort.rawValue)") ?? .sessionSortRecent
    }

    public static func actionOutcome(_ outcome: ActionRecord.Outcome) -> L10nKey {
        L10nKey(rawValue: "actionRecord.\(outcome.rawValue)") ?? .actionRecordCompleted
    }
}

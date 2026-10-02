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

    public static func itemType(_ type: ContextItemType) -> L10nKey {
        switch type {
        case .text: .itemTypeText
        case .url: .itemTypeUrl
        case .image: .itemTypeImage
        case .pdf: .itemTypePdf
        case .document: .itemTypeDocument
        }
    }
}

// MARK: - SwiftUI

extension Text {
    public init(_ key: L10nKey) {
        self.init(LocalizedStringKey(key.rawValue), bundle: L10n.bundle)
    }
}

import Foundation
import TLCoreServices
import TLDomain

/// What the host can do. The share extension cannot open URLs or navigate,
/// so those actions point the user to the app instead.
public struct ActionCapabilities: Sendable, Equatable {
    public var canOpenURLs: Bool
    public var canNavigate: Bool
    public var canShare: Bool

    public init(canOpenURLs: Bool, canNavigate: Bool, canShare: Bool) {
        self.canOpenURLs = canOpenURLs
        self.canNavigate = canNavigate
        self.canShare = canShare
    }

    public static let app = ActionCapabilities(canOpenURLs: true, canNavigate: true, canShare: true)
    public static let shareExtension = ActionCapabilities(canOpenURLs: false, canNavigate: false, canShare: false)
}

/// How a suggested action is carried out. Pure, so it is unit-tested; the view
/// only executes the plan.
public enum ActionPlan: Equatable, Sendable {
    /// Opened by the system: `tel:`, `sms:`, `mailto:`, Apple Maps or a web page.
    case open(URL)
    case copy(String)
    case share(String)
    case save
    /// Opens the calculator starting from this value.
    case calculate(Decimal)
    case translate(String)
    /// Shown honestly as not implemented yet.
    case comingLater
    /// Needs the full app (share extension).
    case openApp
    case unavailable

    public static func make(for action: Action, content: ContextContent?, capabilities: ActionCapabilities = .app) -> ActionPlan {
        if action.isPlaceholder { return .comingLater }
        let value = action.valueText
        let text = plainText(content) ?? value

        func opening(_ url: URL?) -> ActionPlan {
            guard let url else { return .unavailable }
            return capabilities.canOpenURLs ? .open(url) : .openApp
        }

        switch action.type {
        case .saveToSession:
            return .save
        case .copy:
            return text.map(ActionPlan.copy) ?? .unavailable
        case .share:
            guard let text else { return .unavailable }
            return capabilities.canShare ? .share(text) : .openApp
        case .openURL:
            guard let url = value.flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme?.lowercased()) else {
                return .unavailable
            }
            return opening(url)
        case .call:
            return opening(phoneURL(scheme: "tel", value))
        case .sendMessage:
            return opening(phoneURL(scheme: "sms", value))
        case .sendEmail:
            return opening(value.flatMap(emailURL))
        case .openInMaps:
            return opening(value.flatMap(mapsURL))
        case .calculate:
            guard let number = value.flatMap({ Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }) else {
                return .unavailable
            }
            return capabilities.canNavigate ? .calculate(number) : .openApp
        case .translate:
            return text.map(ActionPlan.translate) ?? .unavailable
        case .summarize, .createReminder, .addToCalendar, .convertCurrency, .addContact:
            return .comingLater
        default:
            return .unavailable
        }
    }

    private static func plainText(_ content: ContextContent?) -> String? {
        switch content {
        case .text(let text): text
        case .url(let url): url.absoluteString
        case .file, nil: nil
        }
    }

    /// Keeps the leading `+` and digits only, so `tel:` and `sms:` URLs are valid.
    static func phoneURL(scheme: String, _ value: String?) -> URL? {
        guard let value else { return nil }
        let normalized = ContextEngine.normalizeDigits(value)
        var digits = normalized.filter(\.isASCIIDigitCharacter)
        guard digits.count >= 3 else { return nil }
        if normalized.trimmingCharacters(in: .whitespaces).hasPrefix("+") { digits = "+" + digits }
        return URL(string: "\(scheme):\(digits)")
    }

    static func emailURL(_ value: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return components.path.contains("@") ? components.url : nil
    }

    /// Apple Maps universal link; opens the Maps app.
    static func mapsURL(_ value: String) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: value)]
        return components?.url
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool { ("0"..."9").contains(self) }
}

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
    /// Asks the user for a rate, then opens the calculator with the result.
    /// TaskLens has no live exchange rates and never guesses one.
    case convert(Decimal, currency: String?)
    case translate(String)
    /// Opens the note editor with this text.
    case createNote(String)
    /// Searches what the user saved in TaskLens.
    case search(String)
    /// Opens the system event editor, filled in. The user confirms or cancels.
    case createEvent(EventDraft)
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
        case .createNote:
            guard let text, !text.isEmpty else { return .unavailable }
            return capabilities.canNavigate ? .createNote(text) : .openApp
        case .search:
            guard let query = text.map(searchQuery), !query.isEmpty else { return .unavailable }
            return capabilities.canNavigate ? .search(query) : .openApp
        case .addToCalendar:
            guard let draft = EventDraft(action: action) else { return .unavailable }
            return capabilities.canNavigate ? .createEvent(draft) : .openApp
        case .extractText:
            // Extract lists the useful parts of a text (numbers, links, dates) and copies them.
            guard let values = action.parameters[Action.ParameterKey.values]?.arrayValue?.compactMap(\.stringValue),
                  !values.isEmpty else { return .unavailable }
            return .copy(values.joined(separator: "\n"))
        case .convertCurrency:
            guard let amount = value.flatMap({ Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }) else {
                return .unavailable
            }
            return capabilities.canNavigate
                ? .convert(amount, currency: action.parameters[Action.ParameterKey.currencyCode]?.stringValue)
                : .openApp
        case .summarize, .createReminder, .addContact, .askAI:
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

    /// The user's rate: "1310", "1,310.5", "١٣١٠٫٥". Nil unless above zero.
    public static func rate(from text: String) -> Decimal? {
        let arabicDigits = Array("٠١٢٣٤٥٦٧٨٩")
        var cleaned = String(text.trimmingCharacters(in: .whitespaces).map { character in
            arabicDigits.firstIndex(of: character).map { Character(String($0)) } ?? character
        })
        cleaned = cleaned.replacingOccurrences(of: "٫", with: ".").replacingOccurrences(of: "٬", with: "")
        // A lone comma is a decimal point ("0,92"); with a dot it groups thousands.
        cleaned = cleaned.contains(".") ? cleaned.replacingOccurrences(of: ",", with: "")
                                        : cleaned.replacingOccurrences(of: ",", with: ".")
        guard let rate = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")), rate > 0 else { return nil }
        return rate
    }

    /// amount × rate, rounded to 4 places like the calculator.
    public static func converted(_ amount: Decimal, rate: Decimal) -> Decimal {
        var product = amount * rate
        var rounded = Decimal()
        NSDecimalRound(&rounded, &product, 4, .bankers)
        return rounded
    }

    /// First line of the text, short enough for a search field.
    public static func searchQuery(_ text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        return String(firstLine.trimmingCharacters(in: .whitespaces).prefix(100))
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

/// A new calendar event, prepared from a date the Context Engine found.
public struct EventDraft: Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var title: String
    public var start: Date
    public var isAllDay: Bool

    public init(title: String, start: Date, isAllDay: Bool) {
        self.title = title
        self.start = start
        self.isAllDay = isAllDay
    }

    /// From an Add to Calendar action: its ISO date value, time flag and title.
    public init?(action: Action) {
        guard let value = action.valueText else { return nil }
        let includesTime = action.parameters[Action.ParameterKey.includesTime]?.boolValue ?? false
        let formatter = ISO8601DateFormatter()
        if includesTime {
            formatter.formatOptions = [.withInternetDateTime]
        } else {
            formatter.formatOptions = [.withFullDate]
            formatter.timeZone = .current
        }
        guard let date = formatter.date(from: value) else { return nil }
        self.init(
            title: action.parameters[Action.ParameterKey.title]?.stringValue ?? "",
            start: date,
            isAllDay: !includesTime
        )
    }

    /// One hour for a timed event; the same day for an all-day event.
    public var end: Date {
        isAllDay ? start : start.addingTimeInterval(60 * 60)
    }

    public static func == (lhs: EventDraft, rhs: EventDraft) -> Bool {
        lhs.title == rhs.title && lhs.start == rhs.start && lhs.isAllDay == rhs.isAllDay
    }
}

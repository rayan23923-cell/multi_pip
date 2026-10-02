import Foundation
import TLDomain

/// `tasklens://` links used by widgets, App Shortcuts and Live Activities.
/// Parsing is strict: an unknown or malformed link opens nothing.
public enum DeepLink {
    public static let scheme = "tasklens"
    /// Longest text a link may carry into Lens.
    public static let maximumTextLength = 2_000

    /// The route and tab a link opens. Nil when the link is not TaskLens's or not valid.
    public static func route(for url: URL) -> (route: AppRoute?, tab: AppTab)? {
        guard url.scheme?.lowercased() == scheme, let host = url.host()?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch (host, parts.count) {
        case ("commandcenter", 0): return (nil, .commandCenter)
        case ("lens", 0):
            let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "text" }?.value
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (.lensInput(String(text.prefix(maximumTextLength))), .commandCenter)
            }
            return (.lens, .commandCenter)
        case ("clipboard", 0): return (.clipboard, .commandCenter)
        case ("notes", 0): return (.notes(nil), .commandCenter)
        case ("calculator", 0): return (.calculator(nil), .commandCenter)
        case ("pip", 0): return (.pip, .commandCenter)
        case ("workspaces", 0): return (nil, .workspaces)
        case ("workspace", 1):
            guard let id = WorkspaceID(uuidString: parts[0]) else { return nil }
            return (.workspace(id), .workspaces)
        case ("session", 1):
            guard let id = SessionID(uuidString: parts[0]) else { return nil }
            return (.session(id), .workspaces)
        case ("session", 2) where parts[1] == "resume":
            guard let id = SessionID(uuidString: parts[0]) else { return nil }
            return (.sessionResume(id), .workspaces)
        default:
            return nil
        }
    }

    public static var commandCenter: URL { url("commandcenter") }
    public static var lens: URL { url("lens") }
    public static var clipboard: URL { url("clipboard") }
    public static var notes: URL { url("notes") }
    public static var calculator: URL { url("calculator") }
    public static var pip: URL { url("pip") }
    public static var workspaces: URL { url("workspaces") }

    /// Lens analyzing `text` (Send to TaskLens).
    public static func lens(text: String) -> URL {
        // Encoded by hand: `queryItems` leaves "&", "=" and "+" as they are,
        // which would cut or change the text when it is read back.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        let encoded = String(text.prefix(maximumTextLength)).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        var components = URLComponents(url: lens, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = "text=" + encoded
        return components.url!
    }

    public static func workspace(_ id: WorkspaceID) -> URL { url("workspace", id.uuidString) }
    public static func session(_ id: SessionID) -> URL { url("session", id.uuidString) }
    public static func resume(_ id: SessionID) -> URL { url("session", id.uuidString, "resume") }

    private static func url(_ host: String, _ path: String...) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path.isEmpty ? "" : "/" + path.joined(separator: "/")
        return components.url!
    }
}

extension AppRouter {
    /// Opens a `tasklens://` link. Returns false for links TaskLens does not handle.
    @discardableResult
    public func open(_ url: URL) -> Bool {
        guard let target = DeepLink.route(for: url) else { return false }
        if let route = target.route {
            open(route, in: target.tab)
        } else {
            selectedTab = target.tab
            popToRoot(target.tab)
        }
        return true
    }
}

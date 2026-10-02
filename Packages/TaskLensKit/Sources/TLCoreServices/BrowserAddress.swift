import Foundation
import TLDomain
import TLFoundation

/// Turns what the user typed in the browser's address field into a web URL.
///
/// Only http and https are accepted, so the browser can never be pointed at
/// `file:`, `javascript:` or `data:` URLs. Text without a scheme that looks like
/// a host gets `https://`. There is no search fallback: typed text is never sent
/// to a search engine.
public enum BrowserAddress {
    public static let allowedSchemes: Set<String> = ["http", "https"]

    public static func url(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }

        if trimmed.contains("://") {
            guard let components = URLComponents(string: trimmed),
                  let scheme = components.scheme?.lowercased(),
                  allowedSchemes.contains(scheme)
            else { return nil }
            return validated(components)
        }

        // Anything else with a scheme ("javascript:", "mailto:") is rejected;
        // "host:port" is not a scheme.
        guard looksLikeHost(trimmed) || looksLikeHostWithPort(trimmed) else { return nil }
        guard let components = URLComponents(string: "https://" + trimmed) else { return nil }
        return validated(components)
    }

    private static func validated(_ components: URLComponents) -> URL? {
        guard let host = components.host, !host.isEmpty, let url = components.url else { return nil }
        return url
    }

    /// "example.com", "sub.example.co/path", "localhost:8080".
    private static func looksLikeHost(_ text: String) -> Bool {
        let host = text.split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? text
        let name = host.split(separator: ":").first.map(String.init) ?? host
        if name.lowercased() == "localhost" { return true }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        return labels.last.map { $0.allSatisfy(\.isLetter) || $0.allSatisfy(\.isNumber) } ?? false
    }

    private static func looksLikeHostWithPort(_ text: String) -> Bool {
        let parts = text.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return false }
        let port = parts[1].prefix(while: \.isNumber)
        return !port.isEmpty && looksLikeHost(String(parts[0]))
    }

    /// The URL as a context item payload, with the page title when known.
    public static func output(for url: URL, title: String?) -> ToolOutput {
        var metadata: Metadata = [:]
        if let title, !title.isEmpty { metadata["title"] = .string(title) }
        return ToolOutput(tool: .browser, source: .browser, content: .url(url), metadata: metadata)
    }
}

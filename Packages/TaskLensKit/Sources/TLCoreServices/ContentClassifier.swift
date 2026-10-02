import Foundation
import TLDomain

/// Minimal, rule-based classification of raw input into `ContextContent`.
///
/// This only separates links from text. Entity-level understanding
/// (phones, prices, dates) belongs to the Context Engine.
public enum ContentClassifier {
    /// Schemes treated as links when the whole input is a single URL.
    public static let linkSchemes: Set<String> = ["http", "https"]

    public static func classify(_ raw: String) -> ContextContent {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(where: \.isWhitespace),
           let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           linkSchemes.contains(scheme),
           let host = url.host, !host.isEmpty {
            return .url(url)
        }
        return .text(raw)
    }
}

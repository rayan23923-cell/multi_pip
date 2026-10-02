import SwiftUI
import TLDomain

/// Spacing scale. Use these instead of literal numbers so density stays consistent.
public enum TLSpacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

public enum TLRadius {
    public static let small: CGFloat = 8
    public static let card: CGFloat = 14
}

extension WorkspaceColor {
    /// Semantic tag to system color. System colors adapt to light/dark mode
    /// and increased contrast automatically.
    public var color: Color {
        switch self {
        case .blue: .blue
        case .green: .green
        case .orange: .orange
        case .purple: .purple
        case .pink: .pink
        default: .gray
        }
    }
}

extension SessionState {
    public var tint: Color {
        switch self {
        case .active: .green
        case .paused: .orange
        case .ended: .secondary
        }
    }
}

extension ContextItemType {
    public var symbolName: String {
        switch self {
        case .text: "text.alignleft"
        case .url: "link"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .document: "doc"
        }
    }
}

extension SessionKind {
    public var symbolName: String {
        switch self {
        case .research: "magnifyingglass"
        case .shopping: "cart"
        case .study: "book"
        case .developer: "chevron.left.forwardslash.chevron.right"
        default: "square.stack"
        }
    }
}

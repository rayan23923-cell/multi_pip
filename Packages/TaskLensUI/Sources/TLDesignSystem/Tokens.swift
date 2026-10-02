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
        case .teal: .teal
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

extension WorkspaceTool {
    public var symbolName: String {
        switch self {
        case .notes: "note.text"
        case .calculator: "plusminus"
        case .browser: "safari"
        case .documents: "doc.on.doc"
        case .clipboard: "doc.on.clipboard"
        case .lens: "viewfinder"
        default: "wrench.and.screwdriver"
        }
    }
}

/// Curated SF Symbols offered in the workspace icon picker.
public enum WorkspaceIconCatalog {
    public static let symbols: [String] = [
        "square.grid.2x2", "book.closed", "graduationcap", "briefcase", "building.2",
        "cart", "bag", "creditcard", "chevron.left.forwardslash.chevron.right", "hammer",
        "terminal", "lightbulb", "star", "heart", "house", "airplane", "car",
        "figure.run", "fork.knife", "music.note", "camera", "paintpalette", "leaf", "globe",
    ]
}

import Foundation
import TLFoundation

public typealias WorkspaceID = Identifier<Workspace>

/// A long-lived container that groups sessions, notes and documents
/// around one area of the user's work (a course, a job, a shopping list).
public struct Workspace: Entity {
    public static let entityName = "workspace"
    public static let maximumNameLength = 80

    public let id: WorkspaceID
    public var name: String
    public var kind: WorkspaceKind
    /// SF Symbol name.
    public var symbolName: String
    public var color: WorkspaceColor
    /// Tools shown in the workspace, in display order.
    public var tools: [WorkspaceTool]
    public var settings: WorkspaceSettings
    public var isFavorite: Bool
    public var isArchived: Bool
    public var sortOrder: Int
    public let createdAt: Date
    public var updatedAt: Date
    public var lastOpenedAt: Date?
    public var metadata: Metadata

    public init(
        id: WorkspaceID = WorkspaceID(),
        name: String,
        kind: WorkspaceKind = .custom,
        symbolName: String? = nil,
        color: WorkspaceColor? = nil,
        tools: [WorkspaceTool]? = nil,
        settings: WorkspaceSettings? = nil,
        isFavorite: Bool = false,
        isArchived: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date,
        updatedAt: Date? = nil,
        lastOpenedAt: Date? = nil,
        metadata: Metadata = [:]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.symbolName = symbolName ?? kind.defaultSymbolName
        self.color = color ?? kind.defaultColor
        self.tools = tools ?? kind.defaultTools
        self.settings = settings ?? WorkspaceSettings(kind: kind)
        self.isFavorite = isFavorite
        self.isArchived = isArchived
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastOpenedAt = lastOpenedAt
        self.metadata = metadata
    }
}

extension Workspace {
    enum CodingKeys: String, CodingKey {
        case id, name, kind, symbolName, color, tools, settings, isFavorite, isArchived
        case sortOrder, createdAt, updatedAt, lastOpenedAt, metadata
    }

    /// Tolerant decoding: fields added after the first release fall back to
    /// the kind's defaults, so older stores keep loading.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(WorkspaceKind.self, forKey: .kind) ?? .custom
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.init(
            id: try container.decode(WorkspaceID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            kind: kind,
            symbolName: try container.decodeIfPresent(String.self, forKey: .symbolName),
            color: try container.decodeIfPresent(WorkspaceColor.self, forKey: .color),
            tools: try container.decodeIfPresent([WorkspaceTool].self, forKey: .tools),
            settings: try container.decodeIfPresent(WorkspaceSettings.self, forKey: .settings),
            isFavorite: try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false,
            isArchived: try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false,
            sortOrder: try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0,
            createdAt: createdAt,
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt),
            lastOpenedAt: try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt),
            metadata: try container.decodeIfPresent(Metadata.self, forKey: .metadata) ?? [:]
        )
    }
}

/// What the workspace is for. Drives default icon, color, tools and session kind.
public struct WorkspaceKind: ExtensibleKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let study: WorkspaceKind = "study"
    public static let work: WorkspaceKind = "work"
    public static let shopping: WorkspaceKind = "shopping"
    public static let developer: WorkspaceKind = "developer"
    public static let custom: WorkspaceKind = "custom"
    public static let research: WorkspaceKind = "research"

    public static let allKnown: [WorkspaceKind] = [.study, .research, .work, .shopping, .developer, .custom]

    public var defaultSymbolName: String {
        switch self {
        case .study: "book.closed"
        case .work: "briefcase"
        case .shopping: "cart"
        case .developer: "chevron.left.forwardslash.chevron.right"
        case .research: "magnifyingglass"
        default: "square.grid.2x2"
        }
    }

    public var defaultColor: WorkspaceColor {
        switch self {
        case .study: .purple
        case .work: .blue
        case .shopping: .orange
        case .developer: .green
        case .research: .teal
        default: .gray
        }
    }

    public var defaultTools: [WorkspaceTool] {
        switch self {
        case .study: [.notes, .documents, .calculator, .lens]
        case .work: [.notes, .documents, .browser, .clipboard]
        case .shopping: [.browser, .calculator, .clipboard, .lens]
        case .developer: [.browser, .clipboard, .notes, .lens]
        case .research: [.browser, .documents, .notes, .lens]
        default: [.notes, .clipboard]
        }
    }

    public var defaultSessionKind: SessionKind {
        switch self {
        case .study: .study
        case .shopping: .shopping
        case .developer: .developer
        case .research: .research
        default: .general
        }
    }
}

/// A tool a workspace exposes. Tools without a screen yet are shown as upcoming.
public struct WorkspaceTool: ExtensibleKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let notes: WorkspaceTool = "notes"
    public static let calculator: WorkspaceTool = "calculator"
    public static let browser: WorkspaceTool = "browser"
    public static let documents: WorkspaceTool = "documents"
    public static let clipboard: WorkspaceTool = "clipboard"
    public static let lens: WorkspaceTool = "lens"

    public static let allKnown: [WorkspaceTool] = [.notes, .calculator, .browser, .documents, .clipboard, .lens]
}

/// Per-workspace preferences.
public struct WorkspaceSettings: Codable, Sendable, Hashable {
    /// Kind used when a session is started from this workspace.
    public var defaultSessionKind: SessionKind
    /// When the workspace is opened and nothing is active, resume its most recent paused session.
    public var resumesLastSession: Bool

    public init(defaultSessionKind: SessionKind = .general, resumesLastSession: Bool = false) {
        self.defaultSessionKind = defaultSessionKind
        self.resumesLastSession = resumesLastSession
    }

    public init(kind: WorkspaceKind) {
        self.init(defaultSessionKind: kind.defaultSessionKind)
    }

    enum CodingKeys: String, CodingKey {
        case defaultSessionKind, resumesLastSession
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultSessionKind = try container.decodeIfPresent(SessionKind.self, forKey: .defaultSessionKind) ?? .general
        resumesLastSession = try container.decodeIfPresent(Bool.self, forKey: .resumesLastSession) ?? false
    }
}

/// Editable fields of a workspace, used by create and edit forms.
public struct WorkspaceDraft: Sendable, Hashable {
    public var name: String
    public var kind: WorkspaceKind
    public var symbolName: String
    public var color: WorkspaceColor
    public var tools: [WorkspaceTool]
    public var settings: WorkspaceSettings

    public init(
        name: String = "",
        kind: WorkspaceKind = .custom,
        symbolName: String? = nil,
        color: WorkspaceColor? = nil,
        tools: [WorkspaceTool]? = nil,
        settings: WorkspaceSettings? = nil
    ) {
        self.name = name
        self.kind = kind
        self.symbolName = symbolName ?? kind.defaultSymbolName
        self.color = color ?? kind.defaultColor
        self.tools = tools ?? kind.defaultTools
        self.settings = settings ?? WorkspaceSettings(kind: kind)
    }

    public init(_ workspace: Workspace) {
        self.init(
            name: workspace.name,
            kind: workspace.kind,
            symbolName: workspace.symbolName,
            color: workspace.color,
            tools: workspace.tools,
            settings: workspace.settings
        )
    }

    /// Switches kind and resets the kind-driven defaults (icon, color, tools,
    /// session kind) unless the user already changed them.
    public mutating func applyKind(_ newKind: WorkspaceKind) {
        let old = WorkspaceDraft(kind: kind)
        if symbolName == old.symbolName { symbolName = newKind.defaultSymbolName }
        if color == old.color { color = newKind.defaultColor }
        if tools == old.tools { tools = newKind.defaultTools }
        if settings.defaultSessionKind == old.settings.defaultSessionKind {
            settings.defaultSessionKind = newKind.defaultSessionKind
        }
        kind = newKind
    }
}

/// Semantic color tag. The design system decides the actual color.
public struct WorkspaceColor: ExtensibleKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let blue: WorkspaceColor = "blue"
    public static let green: WorkspaceColor = "green"
    public static let orange: WorkspaceColor = "orange"
    public static let purple: WorkspaceColor = "purple"
    public static let pink: WorkspaceColor = "pink"
    public static let teal: WorkspaceColor = "teal"
    public static let gray: WorkspaceColor = "gray"

    public static let allKnown: [WorkspaceColor] = [.blue, .green, .orange, .purple, .pink, .teal, .gray]
}

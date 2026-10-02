import SwiftUI
import TLDesignSystem
import TLDomain
import TLLocalization

/// "Detected type: Phone Number" row.
public struct DetectedTypeRow: View {
    private let category: ContentCategory

    public init(_ category: ContentCategory) {
        self.category = category
    }

    public var body: some View {
        LabeledContent {
            Text(L10nKey.category(category))
                .accessibilityIdentifier("analysis.category.\(category.rawValue)")
        } label: {
            Label {
                Text(L10nKey.lensDetectedType)
            } icon: {
                Image(systemName: category.symbolName)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("analysis.detectedType")
    }
}

/// Entities found inside the content (phones, links, dates in a paragraph).
/// Hidden when the only entity is the content itself.
public struct EntitiesSection: View {
    private let entities: [DetectedEntity]

    public init(_ entities: [DetectedEntity]) {
        self.entities = entities.filter { $0.metadata[ContextAnalysis.primaryKey]?.boolValue != true }
    }

    public var body: some View {
        if !entities.isEmpty {
            Section {
                ForEach(entities) { entity in
                    LabeledContent {
                        Text(entity.matchedText ?? "")
                            .lineLimit(2)
                            .textSelection(.enabled)
                    } label: {
                        Text(L10nKey.entityType(entity.type))
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text(L10nKey.actionsFound)
            }
        }
    }
}

/// Short, safe preview of text content. Long text is cut so huge pastes stay fast.
public struct ContentPreview: View {
    private let content: ContextContent
    private let lineLimit: Int

    public static let maximumCharacters = 600

    public init(_ content: ContextContent, lineLimit: Int = 6) {
        self.content = content
        self.lineLimit = lineLimit
    }

    public var body: some View {
        switch content {
        case .text(let text):
            Text(verbatim: String(text.prefix(Self.maximumCharacters)))
                .lineLimit(lineLimit)
        case .url(let url):
            Text(verbatim: url.absoluteString)
                .foregroundStyle(.tint)
                .lineLimit(3)
                .environment(\.layoutDirection, .leftToRight)
        case .file(let reference):
            Label {
                Text(verbatim: reference.originalFilename ?? reference.relativePath)
            } icon: {
                Image(systemName: content.itemType.symbolName)
            }
        }
    }
}

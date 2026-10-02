import SwiftUI
import TLCoreServices
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

/// The detected value in clear form ("$125" → "US$125.00", a date in the
/// user's format, a dialable phone number) and how sure the engine is.
/// Hidden when the content is not one single value.
public struct DetectedValueRow: View {
    private let entity: DetectedEntity?

    public init(_ analysis: ContextAnalysis) {
        entity = analysis.primaryEntity.flatMap { entity in
            [EntityType.json, .code].contains(entity.type) ? nil : entity
        }
    }

    public var body: some View {
        if let entity {
            LabeledContent {
                VStack(alignment: .trailing, spacing: TLSpacing.xxs) {
                    value(entity)
                        .textSelection(.enabled)
                    Text(Self.confidenceKey(entity.confidence))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } label: {
                Text(L10nKey.analysisValue)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("analysis.value")
        }
    }

    @ViewBuilder
    private func value(_ entity: DetectedEntity) -> some View {
        switch entity.value {
        case .currency(let amount, let code?):
            Text(amount, format: .currency(code: code))
        case .currency(let amount, nil), .number(let amount):
            Text(amount, format: .number)
        case .date(let date):
            if entity.metadata[DetectionKey.includesTime]?.boolValue == true {
                Text(date, format: .dateTime.weekday().day().month().year().hour().minute())
            } else {
                Text(date, format: .dateTime.weekday().day().month().year())
            }
        case .phoneNumber(let phone):
            Text(verbatim: phone).environment(\.layoutDirection, .leftToRight)
        case .url(let url):
            Text(verbatim: url.host() ?? url.absoluteString).environment(\.layoutDirection, .leftToRight)
        case .email(let email):
            Text(verbatim: email).environment(\.layoutDirection, .leftToRight)
        case .address, .text:
            Text(verbatim: entity.normalizedText ?? "").lineLimit(3)
        }
    }

    static func confidenceKey(_ confidence: Confidence) -> L10nKey {
        if confidence >= .high { return .analysisConfidenceHigh }
        if confidence >= .medium { return .analysisConfidenceMedium }
        return .analysisConfidenceLow
    }
}

/// Entities found inside the content (phones, links, dates in a paragraph).
/// Hidden when the only entity is the content itself.
public struct EntitiesSection: View {
    private let entities: [DetectedEntity]

    public init(_ entities: [DetectedEntity]) {
        // Numbers inside a sentence are only listed when they are something more (a price, a date).
        self.entities = entities.filter { !$0.isPrimary && $0.confidence >= .medium }
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

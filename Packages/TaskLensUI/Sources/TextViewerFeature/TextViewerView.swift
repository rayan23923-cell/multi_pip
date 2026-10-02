import SwiftUI
import TLDesignSystem
import TLDomain
import TLLocalization
import UIKit

public struct TextViewerView: View {
    @State private var model: TextViewerModel
    /// Follows Dynamic Type on top of the size the user picked.
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1

    public init(model: TextViewerModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TLSpacing.m) {
                if model.isTruncated {
                    Label { Text(L10nKey.textTruncated) } icon: { Image(systemName: "scissors") }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(model.attributedText)
                    .font(.system(size: model.fontSize * textScale, design: model.isMonospaced ? .monospaced : .default))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("text.content")
            }
            .padding(TLSpacing.l)
        }
        .overlay {
            if !model.hasLoaded && model.errorMessage == nil { ProgressView() }
        }
        .navigationTitle(model.document?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.query, prompt: Text(L10nKey.textSearchPrompt))
        .toolbar {
            ToolbarItem(placement: .status) {
                if !model.query.isEmpty {
                    Text(L10n.format(.commonMatchCount, model.matchRanges.count))
                        .font(.footnote.monospacedDigit())
                        .accessibilityIdentifier("text.matchCount")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { UIPasteboard.general.string = model.text } label: {
                        TLLabel(.textCopyAll, systemImage: "doc.on.doc")
                    }
                    ShareLink(item: model.text) { TLLabel(.actionShare, systemImage: "square.and.arrow.up") }
                    Button { Task { await model.saveText() } } label: {
                        TLLabel(.textSaveText, systemImage: "text.badge.plus")
                    }
                    .accessibilityIdentifier("text.saveText")
                    Button { Task { await model.saveDocument() } } label: {
                        TLLabel(.commonSaveToSession, systemImage: "tray.and.arrow.down")
                    }
                    Divider()
                    Toggle(isOn: $model.isMonospaced) { TLLabel(.textMonospaced, systemImage: "textformat") }
                    ControlGroup {
                        Button { model.fontSize = max(model.fontSize - 2, TextViewerModel.fontSizes.lowerBound) } label: {
                            Image(systemName: "textformat.size.smaller")
                        }
                        .accessibilityLabel(Text(L10nKey.textSmaller))
                        Button { model.fontSize = min(model.fontSize + 2, TextViewerModel.fontSizes.upperBound) } label: {
                            Image(systemName: "textformat.size.larger")
                        }
                        .accessibilityLabel(Text(L10nKey.textLarger))
                    } label: {
                        Text(L10nKey.textFontSize)
                    }
                } label: {
                    TLLabel(.commonMore, systemImage: "ellipsis.circle")
                }
                .disabled(!model.hasLoaded)
                .accessibilityIdentifier("text.menu")
            }
        }
        .sensoryFeedback(.success, trigger: model.savedItemCount)
        .task { await model.load() }
        .errorAlert(message: $model.errorMessage)
    }
}

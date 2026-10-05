import SwiftUI
import TLLocalization

/// The recovery screen for a PowerPoint file that can't be presented: what
/// happened, in plain words, and what can be done (A9.5.2).
///
/// Built on the system's `ContentUnavailableView`, like every other empty and
/// error state in TaskLens, with system button styles and semantic colors, so
/// it follows Dynamic Type, dark mode and right-to-left layout. It scrolls
/// when the largest text sizes need more than one screen.
public struct PresentationFailureView: View {
    private let content: PowerPointFailureContent
    private let onAction: (PowerPointFailureContent.Action) -> Void

    public init(_ content: PowerPointFailureContent, onAction: @escaping (PowerPointFailureContent.Action) -> Void) {
        self.content = content
        self.onAction = onAction
    }

    public var body: some View {
        GeometryReader { proxy in
            ScrollView {
                ContentUnavailableView {
                    Label { Text(content.title) } icon: { Image(systemName: content.symbolName) }
                        .accessibilityIdentifier("presentation.failure.title")
                } description: {
                    Text(content.message)
                        .accessibilityIdentifier("presentation.failure.message")
                } actions: {
                    VStack(spacing: 12) {
                        ForEach(Array(content.actions.enumerated()), id: \.element) { position, action in
                            button(action, prominent: position == 0)
                        }
                    }
                }
                .frame(minHeight: proxy.size.height)
            }
        }
    }

    @ViewBuilder
    private func button(_ action: PowerPointFailureContent.Action, prominent: Bool) -> some View {
        let label = Button { onAction(action) } label: {
            Text(Self.title(action)).frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .optionalAccessibilityHint(Self.hint(action))
        .accessibilityIdentifier("presentation.failure.\(action.rawValue)")
        if prominent {
            label.buttonStyle(.borderedProminent)
        } else if action == .cancel {
            label.buttonStyle(.borderless)
        } else {
            label.buttonStyle(.bordered)
        }
    }

    private static func title(_ action: PowerPointFailureContent.Action) -> L10nKey {
        switch action {
        case .retry: .presentationPptxRetry
        case .importPDF: .presentationPptxImportPDF
        case .cancel: .commonCancel
        }
    }

    private static func hint(_ action: PowerPointFailureContent.Action) -> L10nKey? {
        switch action {
        case .retry: .presentationPptxRetryHint
        case .importPDF: .presentationPptxImportPDFHint
        case .cancel: nil
        }
    }
}

private extension View {
    @ViewBuilder
    func optionalAccessibilityHint(_ key: L10nKey?) -> some View {
        if let key { accessibilityHint(Text(key)) } else { self }
    }
}

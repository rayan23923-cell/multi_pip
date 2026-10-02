import SwiftUI
import TLDomain
import TLLocalization

/// Card container with the app's standard padding and background.
public struct TLCardModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .padding(TLSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: TLRadius.card, style: .continuous))
    }
}

extension View {
    public func tlCard() -> some View {
        modifier(TLCardModifier())
    }

    /// Presents `message` in an alert and clears it when dismissed.
    public func errorAlert(message: Binding<String?>) -> some View {
        alert(
            Text(L10nKey.commonErrorTitle),
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            ),
            actions: {
                Button(role: .cancel) {
                    message.wrappedValue = nil
                } label: {
                    Text(L10nKey.commonOk)
                }
            },
            message: {
                Text(message.wrappedValue ?? "")
            }
        )
    }
}

/// A small capsule label, e.g. a session state.
public struct StatusBadge: View {
    private let key: L10nKey
    private let tint: Color

    public init(_ key: L10nKey, tint: Color) {
        self.key = key
        self.tint = tint
    }

    public var body: some View {
        Text(key)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, TLSpacing.s)
            .padding(.vertical, TLSpacing.xxs)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

/// Empty state built on the system component so it matches iOS conventions.
public struct TLEmptyState: View {
    private let title: L10nKey
    private let message: L10nKey
    private let symbolName: String

    public init(title: L10nKey, message: L10nKey, symbolName: String) {
        self.title = title
        self.message = message
        self.symbolName = symbolName
    }

    public var body: some View {
        ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbolName)
            }
        } description: {
            Text(message)
        }
    }
}

/// Label whose title comes from the string catalog.
public struct TLLabel: View {
    private let key: L10nKey
    private let symbolName: String

    public init(_ key: L10nKey, systemImage symbolName: String) {
        self.key = key
        self.symbolName = symbolName
    }

    public var body: some View {
        Label {
            Text(key)
        } icon: {
            Image(systemName: symbolName)
        }
    }
}

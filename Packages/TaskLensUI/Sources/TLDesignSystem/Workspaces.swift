import SwiftUI
import TLDomain
import TLLocalization

/// Rounded square with the workspace symbol on its color.
public struct WorkspaceIcon: View {
    private let symbolName: String
    private let color: WorkspaceColor
    @ScaledMetric private var size: CGFloat

    public init(symbolName: String, color: WorkspaceColor, size: CGFloat = 32) {
        self.symbolName = symbolName
        self.color = color
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    public init(workspace: Workspace, size: CGFloat = 32) {
        self.init(symbolName: workspace.symbolName, color: workspace.color, size: size)
    }

    public var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.color.gradient, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Compact card used in horizontal workspace strips.
public struct WorkspaceCard: View {
    private let workspace: Workspace
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(workspace: Workspace) {
        self.workspace = workspace
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: TLSpacing.s) {
            HStack(alignment: .top) {
                WorkspaceIcon(workspace: workspace, size: 36)
                Spacer(minLength: TLSpacing.s)
                if workspace.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                }
            }
            Text(workspace.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(L10nKey.workspaceKind(workspace.kind))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(TLSpacing.m)
        .frame(width: dynamicTypeSize.isAccessibilitySize ? 280 : 160, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: TLRadius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Tile used for quick actions. Lays out vertically at accessibility text sizes.
public struct QuickActionTile: View {
    private let key: L10nKey
    private let symbolName: String
    private let tint: Color

    public init(_ key: L10nKey, systemImage symbolName: String, tint: Color = .accentColor) {
        self.key = key
        self.symbolName = symbolName
        self.tint = tint
    }

    public var body: some View {
        VStack(spacing: TLSpacing.s) {
            Image(systemName: symbolName)
                .font(.title2)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(key)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 72)
        .padding(.vertical, TLSpacing.s)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: TLRadius.card, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: TLRadius.card, style: .continuous))
    }
}

/// Row-or-column container that switches to a column at accessibility sizes.
public struct AdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat = TLSpacing.s, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: spacing))
            : AnyLayout(HStackLayout(spacing: spacing))
        layout { content }
    }
}

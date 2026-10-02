import SwiftUI
import TLDesignSystem
import TLDomain
import TLLocalization
import UIKit

/// The Picture in Picture workspace: a live preview of the card, start and
/// stop, the kept cards, and what Picture in Picture can and cannot do.
public struct PiPWorkspaceView: View {
    @Bindable private var model: PiPWorkspaceModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.locale) private var locale

    public init(model: PiPWorkspaceModel) {
        self.model = model
    }

    public var body: some View {
        List {
            Section {
                if model.isSupported {
                    PiPSourceView(layer: model.engine.sourceLayer)
                        .aspectRatio(PiPCardView.size.width / PiPCardView.size.height, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: TLRadius.card, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: TLRadius.card, style: .continuous)
                                .strokeBorder(.separator)
                        }
                        .accessibilityElement()
                        .accessibilityLabel(Text(previewLabel))
                        .accessibilityIdentifier("pip.preview")
                        .listRowInsets(EdgeInsets(top: TLSpacing.m, leading: TLSpacing.l, bottom: TLSpacing.m, trailing: TLSpacing.l))
                    statusRow
                    controls
                } else {
                    Label {
                        VStack(alignment: .leading, spacing: TLSpacing.xxs) {
                            Text(L10nKey.pipUnsupportedTitle).font(.headline)
                            Text(L10nKey.pipUnsupportedMessage).font(.subheadline).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "pip.remove")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pip.unsupported")
                }
            } footer: {
                if let reason = model.lastStop {
                    Text(L10nKey.pipStopReason(reason))
                        .accessibilityIdentifier("pip.lastStop")
                }
            }

            Section {
                if model.cards.isEmpty {
                    Text(L10nKey.pipNoCards)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("pip.empty")
                }
                ForEach(model.cards) { card in
                    cardRow(card)
                }
            } header: {
                Text(L10nKey.pipCards)
            } footer: {
                Text(L10nKey.pipCardsHint)
            }

            Section {
                ForEach(Self.limits, id: \.self) { key in
                    Text(key).font(.footnote)
                }
            } header: {
                Text(L10nKey.pipLimitsTitle)
            }
            .accessibilityIdentifier("pip.limits")
        }
        .navigationTitle(Text(L10nKey.pipTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .onAppear {
            updateAppearance()
            model.setPreviewVisible(true)
        }
        .onDisappear { model.setPreviewVisible(false) }
        .onChange(of: colorScheme) { updateAppearance() }
        .onChange(of: model.cards.count) { model.setPreviewVisible(true) }
        .errorAlert(message: $model.errorMessage)
    }

    static let limits: [L10nKey] = [.pipLimitReadOnly, .pipLimitOwnContent, .pipLimitStart, .pipLimitClosed]

    private var previewLabel: String {
        guard let card = model.currentCard else { return L10n.string(.pipNoCards) }
        return [card.title, card.body].filter { !$0.isEmpty }.joined(separator: ". ")
    }

    private func updateAppearance() {
        model.appearance = PiPFrameRenderer.Appearance(colorScheme: colorScheme, layoutDirection: layoutDirection, locale: locale)
        model.showCurrent()
    }

    private var statusRow: some View {
        HStack {
            Text(L10nKey.pipStatus)
            Spacer()
            Text(statusKey)
                .foregroundStyle(model.isActive ? Color.green : Color.secondary)
                .accessibilityIdentifier("pip.status")
        }
        .accessibilityElement(children: .combine)
    }

    private var statusKey: L10nKey {
        switch model.status {
        case .unsupported: .pipUnsupportedTitle
        case .idle: model.isPossible || model.cards.isEmpty ? .pipStatusIdle : .pipStatusUnavailable
        case .starting: .pipStatusStarting
        case .active: .pipStatusActive
        case .stopping: .pipStatusStopping
        }
    }

    @ViewBuilder
    private var controls: some View {
        if model.isActive || model.status == .starting {
            Button(role: .destructive) { model.stop() } label: {
                TLLabel(.pipStop, systemImage: "pip.exit")
            }
            .accessibilityIdentifier("pip.stop")
        } else {
            Button { model.start() } label: {
                TLLabel(.pipStart, systemImage: "pip.enter")
            }
            .disabled(!model.canStart)
            .accessibilityIdentifier("pip.start")
        }
        if model.cards.count > 1 {
            HStack {
                Button { Task { await model.step(by: -1) } } label: {
                    Image(systemName: "chevron.backward")
                        .accessibilityLabel(Text(L10nKey.pipPrevious))
                }
                .disabled(model.currentIndex == 0)
                .accessibilityIdentifier("pip.previous")
                Spacer()
                Text(verbatim: "\(model.currentIndex + 1)/\(model.cards.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("pip.position")
                Spacer()
                Button { Task { await model.step(by: 1) } } label: {
                    Image(systemName: "chevron.forward")
                        .accessibilityLabel(Text(L10nKey.pipNext))
                }
                .disabled(model.currentIndex >= model.cards.count - 1)
                .accessibilityIdentifier("pip.next")
            }
            .buttonStyle(.borderless)
            .imageScale(.large)
        }
    }

    private func cardRow(_ card: PiPCard) -> some View {
        Button { Task { await model.select(card) } } label: {
            HStack(alignment: .top, spacing: TLSpacing.m) {
                VStack(alignment: .leading, spacing: TLSpacing.xxs) {
                    Text(L10nKey.pipKind(card.kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: card.title.isEmpty ? card.body : card.title)
                        .lineLimit(2)
                }
                Spacer()
                if card.id == model.currentCard?.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel(Text(L10nKey.pipShowing))
                }
            }
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pipCard")
        .swipeActions {
            Button(role: .destructive) { Task { await model.remove(card) } } label: {
                TLLabel(.commonDelete, systemImage: "trash")
            }
        }
        .contextMenu {
            Button(role: .destructive) { Task { await model.remove(card) } } label: {
                TLLabel(.commonDelete, systemImage: "trash")
            }
        }
    }
}

/// Hosts the layer Picture in Picture takes its frames from. iOS only opens
/// the window from a layer that is on screen in the app.
struct PiPSourceView: UIViewRepresentable {
    let layer: CALayer?

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.backgroundColor = .secondarySystemBackground
        view.hosted = layer
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        view.hosted = layer
    }

    final class HostView: UIView {
        var hosted: CALayer? {
            didSet {
                guard hosted !== oldValue else { return }
                oldValue?.removeFromSuperlayer()
                if let hosted { layer.addSublayer(hosted) }
                setNeedsLayout()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }
}

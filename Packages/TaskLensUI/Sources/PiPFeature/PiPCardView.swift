import SwiftUI
import TLDesignSystem
import TLDomain
import TLLocalization

/// How a card looks inside the Picture in Picture window and in the preview.
///
/// Drawn at a fixed size and turned into video frames, so it uses large,
/// fixed type that stays readable when the user shrinks the window. Colors
/// and direction follow the app's appearance and language at the moment the
/// frame is drawn.
public struct PiPCardView: View {
    /// Points. The window keeps this 4:3 shape.
    public static let size = CGSize(width: 400, height: 300)

    let card: PiPCard?
    let position: Int
    let count: Int

    public init(card: PiPCard?, position: Int, count: Int) {
        self.card = card
        self.position = position
        self.count = count
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
                Text(kindKey)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if count > 1 {
                    Text(verbatim: "\(position + 1)/\(count)")
                        .font(.system(size: 18, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let card {
                if !card.title.isEmpty {
                    Text(verbatim: card.title)
                        .font(.system(size: 24, weight: .bold))
                        .lineLimit(2)
                }
                if !card.body.isEmpty {
                    Text(verbatim: card.body)
                        .font(.system(size: card.kind == .calculation ? 44 : 22, weight: card.kind == .calculation ? .semibold : .regular))
                        .monospacedDigit()
                        .lineLimit(card.kind == .calculation ? 2 : 7)
                        .minimumScaleFactor(0.6)
                }
                if let page = card.origin.page {
                    Text(L10n.format(.pipPage, page + 1))
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(L10nKey.pipEmptyCard)
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(Color(uiColor: .systemBackground))
    }

    private var kindKey: L10nKey {
        guard let card else { return .pipTitle }
        return L10nKey.pipKind(card.kind)
    }

    private var symbol: String {
        switch card?.kind {
        case .note: "note.text"
        case .document: "doc.richtext"
        case .calculation: "plus.forwardslash.minus"
        case .context: "text.viewfinder"
        case nil: "pip"
        }
    }

    private var tint: Color {
        switch card?.kind {
        case .note: .orange
        case .document: .red
        case .calculation: .blue
        case .context, nil: .accentColor
        }
    }
}

extension L10nKey {
    public static func pipKind(_ kind: PiPCard.Kind) -> L10nKey {
        L10nKey(rawValue: "pip.kind.\(kind.rawValue)") ?? .pipTitle
    }

    public static func pipStopReason(_ reason: PiPPresentation.StopReason) -> L10nKey {
        L10nKey(rawValue: "pip.stopped.\(reason.rawValue)") ?? .pipStoppedUser
    }
}

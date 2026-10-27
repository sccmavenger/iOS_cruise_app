import SwiftUI

/// One playing card. Shared by Spades and Tonk so a card looks identical in both.
///
/// Suit is shown by **symbol as well as colour**, never colour alone, so the card is
/// readable with any form of colour blindness.
struct PlayingCardView: View {
    let card: PlayingCard
    /// Dimmed and non-tappable when this card can't legally be played right now.
    var isPlayable = true
    var isSelected = false
    var size: Size = .hand

    enum Size {
        case hand
        case table
        case small

        var width: CGFloat {
            switch self {
            case .hand: 48
            case .table: 44
            case .small: 32
            }
        }

        var height: CGFloat { width * 1.45 }

        var rankFont: Font {
            switch self {
            case .hand: .system(size: 17, weight: .bold, design: .rounded)
            case .table: .system(size: 16, weight: .bold, design: .rounded)
            case .small: .system(size: 12, weight: .bold, design: .rounded)
            }
        }

        var suitFont: Font {
            switch self {
            case .hand: .system(size: 16)
            case .table: .system(size: 15)
            case .small: .system(size: 11)
            }
        }
    }

    var body: some View {
        VStack(spacing: 1) {
            Text(card.rankName)
                .font(size.rankFont)
            Text(card.suit.symbol)
                .font(size.suitFont)
        }
        .foregroundStyle(card.suit.isRed ? Color.red : Color.black)
        .frame(width: size.width, height: size.height)
        .background(.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? Theme.teal : Color.black.opacity(0.18), lineWidth: isSelected ? 3 : 1)
        }
        .opacity(isPlayable ? 1 : 0.4)
        .offset(y: isSelected ? -10 : 0)
        .animation(.snappy(duration: 0.15), value: isSelected)
        // One element per card: otherwise the rank and the suit each read the label ("King of
        // Clubs, King of Clubs").
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.spokenName)
        .accessibilityValue(isPlayable ? "" : "Can't play this now")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A face-down standard card, for the stock pile. (Color Match has its own `CardBackView`
/// for its non-standard deck.)
struct PlayingCardBackView: View {
    var size: PlayingCardView.Size = .small

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LinearGradient(colors: [Theme.deep, Theme.night], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(0.3), lineWidth: 1)
            }
            .frame(width: size.width, height: size.height)
            .accessibilityHidden(true)
    }
}

/// An empty slot, so a missing pile reads as "nothing here" rather than as a gap.
struct CardSlotView: View {
    var label: String?
    var size: PlayingCardView.Size = .table

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .frame(width: size.width, height: size.height)
            .overlay {
                if let label {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
    }
}

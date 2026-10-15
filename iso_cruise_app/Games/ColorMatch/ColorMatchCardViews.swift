import SwiftUI

// Original Color Match card art, drawn with SwiftUI shapes and SF Symbols.
// Every color also has its own symbol and name so it never relies on hue alone.

extension CardColor {
    var fill: Color {
        switch self {
        case .red: Color(red: 0.84, green: 0.25, blue: 0.27)
        case .yellow: Color(red: 0.98, green: 0.78, blue: 0.16)
        case .green: Color(red: 0.13, green: 0.58, blue: 0.33)
        case .blue: Color(red: 0.12, green: 0.40, blue: 0.78)
        }
    }

    var ink: Color { self == .yellow ? Theme.night : .white }

    var symbol: String {
        switch self {
        case .red: "flame.fill"
        case .yellow: "sun.max.fill"
        case .green: "leaf.fill"
        case .blue: "drop.fill"
        }
    }
}

struct ColorMatchCardView: View {
    let card: Card
    var width: CGFloat = 64
    var isHighlighted = false
    var isDimmed = false

    private var height: CGFloat { width * 1.45 }
    private var ink: Color { card.color?.ink ?? .white }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: width * 0.16, style: .continuous)
                .fill(.white)
            RoundedRectangle(cornerRadius: width * 0.12, style: .continuous)
                .fill(background)
                .padding(width * 0.05)

            VStack(spacing: 0) {
                corner
                Spacer(minLength: 0)
            }
            .padding(width * 0.1)

            centerArt
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(isHighlighted ? 0.35 : 0.2), radius: isHighlighted ? 6 : 2, y: isHighlighted ? 4 : 1)
        .overlay {
            if isHighlighted {
                RoundedRectangle(cornerRadius: width * 0.16, style: .continuous)
                    .strokeBorder(Theme.teal, lineWidth: 3)
            }
        }
        // Keep unplayable cards readable: soften rather than fade them out.
        .saturation(isDimmed ? 0.45 : 1)
        .opacity(isDimmed ? 0.85 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.name)
    }

    private var background: AnyShapeStyle {
        if let color = card.color { return AnyShapeStyle(color.fill.gradient) }
        return AnyShapeStyle(Theme.night.gradient)
    }

    private var corner: some View {
        HStack(spacing: 2) {
            if let color = card.color {
                Image(systemName: color.symbol)
                    .font(.system(size: width * 0.16, weight: .bold))
            }
            Spacer(minLength: 0)
            Text(shortLabel)
                .font(.system(size: width * 0.18, weight: .heavy, design: .rounded))
        }
        .foregroundStyle(ink)
    }

    @ViewBuilder
    private var centerArt: some View {
        switch card.face {
        case .number(let value):
            Text("\(value)")
                .font(.system(size: width * 0.55, weight: .black, design: .rounded))
                .foregroundStyle(ink)
        case .skip:
            Image(systemName: "nosign")
                .font(.system(size: width * 0.42, weight: .bold))
                .foregroundStyle(ink)
        case .reverse:
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: width * 0.38, weight: .bold))
                .foregroundStyle(ink)
        case .drawTwo:
            Text("+2")
                .font(.system(size: width * 0.42, weight: .black, design: .rounded))
                .foregroundStyle(ink)
        case .wild, .wildDrawFour:
            ZStack {
                WildWheel()
                    .frame(width: width * 0.62, height: width * 0.62)
                Text(card.face == .wild ? "★" : "+4")
                    .font(.system(size: width * 0.26, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 1)
            }
        }
    }

    private var shortLabel: String {
        switch card.face {
        case .number(let value): "\(value)"
        case .skip: "⊘"
        case .reverse: "⇄"
        case .drawTwo: "+2"
        case .wild: "W"
        case .wildDrawFour: "+4"
        }
    }
}

/// Four-color wheel used on wild cards and the color picker.
struct WildWheel: View {
    var body: some View {
        ZStack {
            ForEach(Array(CardColor.allCases.enumerated()), id: \.offset) { index, color in
                Circle()
                    .trim(from: CGFloat(index) / 4, to: CGFloat(index + 1) / 4)
                    .stroke(color.fill, lineWidth: 10)
            }
        }
        .padding(5)
        .accessibilityHidden(true)
    }
}

struct CardBackView: View {
    var width: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: width * 0.16, style: .continuous)
                .fill(.white)
            RoundedRectangle(cornerRadius: width * 0.12, style: .continuous)
                .fill(Theme.oceanGradient)
                .padding(width * 0.05)
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: width * 0.34, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(width: width, height: width * 1.45)
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
    }
}

/// Active-color chip: symbol + name + hue.
struct ActiveColorChip: View {
    let color: CardColor

    var body: some View {
        Label(color.name, systemImage: color.symbol)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(color.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(color.fill, in: Capsule())
            .accessibilityLabel("Active color \(color.name)")
    }
}

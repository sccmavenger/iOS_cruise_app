import SwiftUI

/// CruiseLAN's small shared palette, matching the app icon artwork.
enum Theme {
    static let night = Color(red: 0.03, green: 0.10, blue: 0.24)
    static let deep = Color(red: 0.02, green: 0.27, blue: 0.47)
    static let teal = Color(red: 0.00, green: 0.48, blue: 0.62)
    static let foam = Color(red: 0.72, green: 0.95, blue: 0.96)
    static let sunset = Color(red: 1.00, green: 0.60, blue: 0.35)
    static let coral = Color(red: 0.86, green: 0.30, blue: 0.30)

    static let oceanGradient = LinearGradient(
        colors: [sunset.opacity(0.9), coral.opacity(0.75), deep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// Sine-wave band used as decorative "sea" artwork in headers and empty states.
nonisolated struct WaveShape: Shape {
    var amplitude: CGFloat = 8
    var wavelength: CGFloat = 120
    var phase: CGFloat = 0

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        var x: CGFloat = 0
        while x <= rect.width {
            let y = rect.midY + sin((x / wavelength + phase) * 2 * .pi) * amplitude
            path.addLine(to: CGPoint(x: x, y: y))
            x += 2
        }
        path.addLine(to: CGPoint(x: rect.width, y: rect.maxY))
        path.addLine(to: CGPoint(x: 0, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Layered waves, decorative only (hidden from VoiceOver).
struct SeaView: View {
    var body: some View {
        ZStack {
            WaveShape(amplitude: 6, wavelength: 140, phase: 0.1).fill(Theme.teal.opacity(0.55)).offset(y: -10)
            WaveShape(amplitude: 8, wavelength: 180, phase: 0.6).fill(Theme.deep.opacity(0.75))
            WaveShape(amplitude: 5, wavelength: 110, phase: 0.3).fill(Theme.night.opacity(0.85)).offset(y: 14)
        }
        .accessibilityHidden(true)
    }
}

/// Illustrated empty state with the hero artwork.
struct IllustratedMessage: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image("Hero")
                .resizable()
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: 320)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

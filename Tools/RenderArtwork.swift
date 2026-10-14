// Renders CruiseLAN's app icon and illustration assets.
//
// Usage (from the repository root):
//   swift Tools/RenderArtwork.swift iso_cruise_app/Assets.xcassets
//
// The app icon is flattened onto an opaque RGB bitmap because App Store Connect
// rejects icons with an alpha channel (ITMS-90717).

import AppKit
import SwiftUI

// MARK: - Shared palette

enum Palette {
    static let night = Color(red: 0.03, green: 0.10, blue: 0.24)
    static let deep = Color(red: 0.02, green: 0.27, blue: 0.47)
    static let teal = Color(red: 0.00, green: 0.62, blue: 0.70)
    static let foam = Color(red: 0.72, green: 0.95, blue: 0.96)
    static let sunset = Color(red: 1.00, green: 0.60, blue: 0.35)
    static let coral = Color(red: 0.98, green: 0.42, blue: 0.40)
}

/// A horizontal sine-wave band used for the sea.
struct Wave: Shape {
    var amplitude: CGFloat
    var wavelength: CGFloat
    var phase: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        var x: CGFloat = 0
        while x <= rect.width {
            let y = rect.midY + sin((x / wavelength + phase) * 2 * .pi) * amplitude
            path.addLine(to: CGPoint(x: x, y: y))
            x += 2
        }
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}

// MARK: - App icon

struct AppIconArt: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Palette.sunset, Palette.coral, Palette.deep, Palette.night],
                startPoint: .top,
                endPoint: .bottom
            )

            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.95), Palette.sunset.opacity(0)], center: .center, startRadius: 10, endRadius: 260))
                .frame(width: 520, height: 520)
                .offset(y: -150)

            VStack(spacing: 0) {
                Spacer()
                ZStack {
                    Wave(amplitude: 22, wavelength: 300, phase: 0.1).fill(Palette.teal.opacity(0.85)).offset(y: -40)
                    Wave(amplitude: 26, wavelength: 360, phase: 0.55).fill(Palette.deep)
                    Wave(amplitude: 18, wavelength: 260, phase: 0.3).fill(Palette.night).offset(y: 70)
                }
                .frame(height: 380)
            }

            // Two chat bubbles linked by radio waves: "talk to people nearby".
            ZStack {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 330, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
                    .offset(x: -70, y: -30)

                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 150, weight: .heavy))
                    .foregroundStyle(Palette.deep)
                    .offset(x: -70, y: -48)

                Image(systemName: "bubble.right.fill")
                    .font(.system(size: 200, weight: .bold))
                    .foregroundStyle(Palette.foam)
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                    .offset(x: 190, y: 170)

                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 84, weight: .bold))
                    .foregroundStyle(Palette.coral)
                    .offset(x: 190, y: 160)
            }
        }
        .frame(width: 1024, height: 1024)
    }
}

// MARK: - Onboarding / empty-state illustration

struct HeroArt: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.sunset.opacity(0.9), Palette.coral.opacity(0.7), Palette.teal.opacity(0.6)], startPoint: .top, endPoint: .bottom)

            Circle()
                .fill(.white.opacity(0.85))
                .frame(width: 260, height: 260)
                .blur(radius: 6)
                .offset(x: 260, y: -210)

            VStack(spacing: 0) {
                Spacer()
                ZStack {
                    Wave(amplitude: 20, wavelength: 420, phase: 0.2).fill(Palette.teal).offset(y: -60)
                    Wave(amplitude: 24, wavelength: 500, phase: 0.6).fill(Palette.deep).offset(y: -10)
                    Wave(amplitude: 16, wavelength: 360, phase: 0.1).fill(Palette.night).offset(y: 60)
                }
                .frame(height: 420)
            }

            Image(systemName: "ferry.fill")
                .font(.system(size: 260, weight: .regular))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
                .offset(x: 0, y: 40)

            HStack(spacing: 380) {
                PhoneBadge(symbol: "bubble.left.fill", tint: Palette.coral)
                PhoneBadge(symbol: "square.grid.3x3.fill", tint: Palette.teal)
            }
            .offset(y: -150)

            Image(systemName: "wave.3.right")
                .font(.system(size: 90, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .offset(x: -70, y: -150)
            Image(systemName: "wave.3.left")
                .font(.system(size: 90, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .offset(x: 70, y: -150)
        }
        .frame(width: 1200, height: 900)
        .clipped()
    }
}

struct PhoneBadge: View {
    let symbol: String
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(.white)
                .frame(width: 150, height: 260)
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(tint.opacity(0.15))
                .frame(width: 124, height: 226)
            Image(systemName: symbol)
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(tint)
        }
    }
}

// MARK: - Rendering

@MainActor
func render<V: View>(_ view: V, size: CGSize, opaque: Bool) -> Data {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
    renderer.scale = 1
    guard let image = renderer.cgImage else { fatalError("Render failed") }

    let width = Int(size.width), height = Int(size.height)
    let bitmapInfo: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo.rawValue
    ) else { fatalError("Context failed") }
    if opaque {
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let flattened = context.makeImage() else { fatalError("Flatten failed") }

    let rep = NSBitmapImageRep(cgImage: flattened)
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG failed") }
    return png
}

func write(_ data: Data, to url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
    print("Wrote \(url.path)")
}

func writeJSON(_ json: String, to url: URL) {
    write(Data(json.utf8), to: url)
}

@MainActor
func main() {
    let args = CommandLine.arguments
    guard args.count == 2 else {
        print("usage: swift RenderArtwork.swift <path to Assets.xcassets>")
        exit(1)
    }
    let catalog = URL(fileURLWithPath: args[1])

    let iconSet = catalog.appendingPathComponent("AppIcon.appiconset")
    write(render(AppIconArt(), size: CGSize(width: 1024, height: 1024), opaque: true), to: iconSet.appendingPathComponent("AppIcon-1024.png"))
    writeJSON("""
    {
      "images" : [
        {
          "filename" : "AppIcon-1024.png",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }
    """, to: iconSet.appendingPathComponent("Contents.json"))

    let heroSet = catalog.appendingPathComponent("Hero.imageset")
    write(render(HeroArt(), size: CGSize(width: 1200, height: 900), opaque: true), to: heroSet.appendingPathComponent("Hero.png"))
    writeJSON("""
    {
      "images" : [
        {
          "filename" : "Hero.png",
          "idiom" : "universal"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }
    """, to: heroSet.appendingPathComponent("Contents.json"))
}

MainActor.assumeIsolated { main() }

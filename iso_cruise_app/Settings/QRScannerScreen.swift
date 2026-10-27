import SwiftUI

/// Full-screen QR scanner.
///
/// Full screen rather than a row inside the form on purpose: a viewfinder in a grouped-list
/// cell is both hard to aim and layout-fragile, and keeping it out of the form means the
/// surrounding screen's live network diagnostics can't invalidate the camera view.
struct QRScannerScreen: View {
    /// Called with a valid code. The screen stays up until the caller dismisses it.
    let onFound: (LANJoinCode) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var model = QRScannerModel()
    /// Set when a scan produced something that wasn't a CruiseLAN code.
    @State private var rejected = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.failure == nil {
                CameraPreview(session: model.session)
                    .ignoresSafeArea()
                reticle
            }

            VStack {
                Spacer()
                footer
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                model.stop()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding()
            .accessibilityLabel("Close scanner")
        }
        .task {
            await model.start()
        }
        .onDisappear {
            model.stop()
        }
        .onChange(of: model.scannedPayload) { _, payload in
            guard let payload else { return }
            guard let code = LANJoinCode(qrPayload: payload) else {
                // Some other QR code — a Wi-Fi poster, a menu. Say so and keep scanning
                // rather than silently ignoring it, which is what "nothing happens" feels like.
                rejected = true
                model.resumeAfterScan()
                return
            }
            rejected = false
            onFound(code)
            dismiss()
        }
    }

    /// A plain frame to aim with. The system scanner drew this for us; now we draw it.
    private var reticle: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(.white.opacity(0.9), lineWidth: 3)
            .frame(width: 240, height: 240)
            .shadow(radius: 8)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 10) {
            if let failure = model.failure {
                Text(failure.message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                if failure == .permissionDenied, let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") { openURL(url) }
                        .buttonStyle(.borderedProminent)
                }
                Text("You can still type your friend's code instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if rejected {
                Label("That isn't a CruiseLAN code. Point at the code in your friend's app.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.sunset)
            } else {
                Text("Point at the QR code in your friend's CruiseLAN app.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.white)
        .padding()
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.55))
    }
}

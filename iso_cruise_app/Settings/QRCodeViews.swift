import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Renders a join code as a QR code.
///
/// Generated on the device with Core Image — no network, no library. The payload is the same
/// eight characters as the typed code (see `LANJoinCode.qrPayload`), so the code shown
/// underneath always works as a fallback when the camera won't cooperate.
struct QRCodeView: View {
    let payload: String
    var size: CGFloat = 200

    var body: some View {
        if let image {
            Image(uiImage: image)
                .interpolation(.none)   // keep the modules crisp rather than blurred
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .padding(10)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("QR code to join this phone")
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
                .frame(width: size, height: size)
                .overlay { Text("Couldn't draw the code").font(.caption) }
        }
    }

    private var image: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        // Medium error correction: the payload is tiny, so this costs almost nothing and
        // survives a thumb over the corner or a scuffed screen.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Scale up before rasterising; the generator emits roughly one pixel per module.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Owns the camera session for QR scanning.
///
/// **Why AVFoundation rather than `DataScannerViewController`.** The first version used
/// VisionKit's scanner, which gave nicer built-in guidance but put the session lifecycle out
/// of reach: `startScanning()` has to be driven from SwiftUI's update cycle, and because the
/// surrounding screen observes live network diagnostics, the body re-evaluated every few
/// seconds and restarted the scanner before it could ever recognise anything. Owning the
/// session directly makes starting and stopping explicit and happen exactly once.
///
/// The session runs on its own queue — `startRunning()` blocks, and on the main thread that
/// freezes the UI for as long as the camera takes to warm up.
@MainActor
@Observable
final class QRScannerModel: NSObject {
    enum Failure: Equatable {
        case permissionDenied
        case noCamera
        case configurationFailed(String)

        var message: String {
            switch self {
            case .permissionDenied: "CruiseLAN needs camera access to scan a code."
            case .noCamera: "This device has no camera available for scanning."
            case .configurationFailed(let detail): "The camera couldn't start. \(detail)"
            }
        }
    }

    private(set) var failure: Failure?
    private(set) var isRunning = false
    /// The payload of the first CruiseLAN code seen. Set once, then the session stops.
    private(set) var scannedPayload: String?

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "com.dannyguillory.cruiselan.camera")
    @ObservationIgnored private var isConfigured = false

    /// Requests permission, configures the session if needed, and starts it. Safe to call
    /// more than once; only the first call does any work.
    func start() async {
        guard !isRunning else { return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                failure = .permissionDenied
                return
            }
        case .denied, .restricted:
            failure = .permissionDenied
            return
        @unknown default:
            failure = .permissionDenied
            return
        }

        if !isConfigured {
            if let problem = configure() {
                failure = problem
                return
            }
            isConfigured = true
        }

        failure = nil
        isRunning = true
        // `startRunning` blocks until the camera is ready; never on the main thread.
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Lets the screen scan again after a rejected or failed code.
    func resumeAfterScan() {
        scannedPayload = nil
        Task { await start() }
    }

    private func configure() -> Failure? {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video) else {
            return .noCamera
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return .configurationFailed("Input refused.") }
            session.addInput(input)
        } catch {
            return .configurationFailed(error.localizedDescription)
        }

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return .configurationFailed("Output refused.") }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        // Must be set *after* the output joins the session: before that, `availableMetadataObjectTypes`
        // is empty and assigning `.qr` throws. This ordering is the classic trap here.
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            return .configurationFailed("QR codes aren't supported by this camera.")
        }
        output.metadataObjectTypes = [.qr]

        return nil
    }
}

extension QRScannerModel: @MainActor AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        // Delegate queue is `.main` (set in `configure`), so this is main-actor in practice.
        MainActor.assumeIsolated {
            guard scannedPayload == nil else { return }
            for object in metadataObjects {
                guard let code = object as? AVMetadataMachineReadableCodeObject,
                      code.type == .qr,
                      let payload = code.stringValue
                else { continue }
                scannedPayload = payload
                stop()
                return
            }
        }
    }
}

/// Live camera preview for a scanner session.
///
/// The preview layer *is* the view's backing layer, so it resizes with the view instead of
/// needing manual frame bookkeeping on rotation.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        // Deliberately empty. Anything that touches the session here would re-run on every
        // SwiftUI update, which is exactly the bug that broke the first scanner.
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

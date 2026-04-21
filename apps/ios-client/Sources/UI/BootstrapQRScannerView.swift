@preconcurrency import AVFoundation
import SwiftUI

struct BootstrapQRScannerSheet: View {
    let onPayloadScanned: (String) -> Void
    let onScannerFailure: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                QRScannerCameraView(
                    onCodeScanned: onPayloadScanned,
                    onFailure: onScannerFailure
                )
                .overlay(alignment: .bottom) {
                    VStack(spacing: 8) {
                        Text("Point the camera at the pairing QR code from your Mac.")
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                            .padding(.top, 12)
                            .padding(.bottom, 20)
                    }
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
                }
            }
            .background(Color.black)
            .navigationTitle("Scan Pairing Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        onCancel()
                    }
                }
            }
        }
    }
}

private struct QRScannerCameraView: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned, onFailure: onFailure)
    }

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let viewController = QRScannerViewController()
        viewController.delegate = context.coordinator
        return viewController
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}

    final class Coordinator: NSObject, QRScannerViewControllerDelegate {
        private let onCodeScanned: (String) -> Void
        private let onFailure: (String) -> Void
        private var hasHandledResult = false

        init(onCodeScanned: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
            self.onCodeScanned = onCodeScanned
            self.onFailure = onFailure
        }

        func scannerViewController(_ controller: QRScannerViewController, didScan payload: String) {
            guard hasHandledResult == false else { return }
            hasHandledResult = true
            onCodeScanned(payload)
        }

        func scannerViewController(_ controller: QRScannerViewController, didFail message: String) {
            guard hasHandledResult == false else { return }
            hasHandledResult = true
            onFailure(message)
        }
    }
}

private protocol QRScannerViewControllerDelegate: AnyObject {
    func scannerViewController(_ controller: QRScannerViewController, didScan payload: String)
    func scannerViewController(_ controller: QRScannerViewController, didFail message: String)
}

private final class QRScannerViewController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: QRScannerViewControllerDelegate?

    nonisolated(unsafe) private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.apterminal.qr-scanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    nonisolated(unsafe) private var isConfigured = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestCameraAccessAndConfigureIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if isConfigured {
            startSessionIfNeeded()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSessionIfNeeded()
    }

    private func requestCameraAccessAndConfigureIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureCaptureSessionIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.configureCaptureSessionIfNeeded()
                    } else {
                        self.delegate?.scannerViewController(self, didFail: "Camera access was denied.")
                    }
                }
            }
        case .denied, .restricted:
            delegate?.scannerViewController(self, didFail: "Camera access is unavailable.")
        @unknown default:
            delegate?.scannerViewController(self, didFail: "Camera access state is unsupported.")
        }
    }

    private func configureCaptureSessionIfNeeded() {
        guard isConfigured == false else { return }

        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.insertSublayer(previewLayer, at: 0)
        self.previewLayer = previewLayer

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .high

            guard let device = AVCaptureDevice.default(for: .video) else {
                self.captureSession.commitConfiguration()
                self.reportFailure("No camera is available on this device.")
                return
            }

            do {
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    try device.lockForConfiguration()
                    device.focusMode = .continuousAutoFocus
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                    device.unlockForConfiguration()
                }
            } catch {
                // Ignore autofocus tuning failures and continue with default device configuration.
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.captureSession.canAddInput(input) else {
                    self.captureSession.commitConfiguration()
                    self.reportFailure("Unable to configure the camera input.")
                    return
                }
                self.captureSession.addInput(input)
            } catch {
                self.captureSession.commitConfiguration()
                self.reportFailure("Unable to initialize the camera.")
                return
            }

            let output = AVCaptureMetadataOutput()
            guard self.captureSession.canAddOutput(output) else {
                self.captureSession.commitConfiguration()
                self.reportFailure("Unable to configure QR code scanning.")
                return
            }

            self.captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            self.captureSession.commitConfiguration()

            self.isConfigured = true
            self.startSessionIfNeeded()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard
            let readableObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
            readableObject.type == .qr,
            let payload = readableObject.stringValue
        else {
            return
        }

        stopSessionIfNeeded()
        delegate?.scannerViewController(self, didScan: payload)
    }

    nonisolated private func startSessionIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.isConfigured else { return }
            guard self.captureSession.isRunning == false else { return }
            self.captureSession.startRunning()
        }
    }

    nonisolated private func stopSessionIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.captureSession.isRunning else { return }
            self.captureSession.stopRunning()
        }
    }

    nonisolated private func reportFailure(_ message: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.scannerViewController(self, didFail: message)
        }
    }
}

import SwiftUI
import AVFoundation
import Combine
import BvfAppKit

struct RecordingView: View {
    @Environment(iCloudManager.self) var cloudManager
    @StateObject private var model = VideoRecordingModel()
    @State private var lastSaveDate: Date?
    @State private var errorMessage: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var availableCameras: [AVCaptureDevice] = []
    @State private var currentPosition: AVCaptureDevice.Position = .back
    @State private var currentDevice: AVCaptureDevice?

    var body: some View {
        ZStack {
            // Camera preview
            CameraPreviewView(session: model.session, device: currentDevice)
                .ignoresSafeArea()

            VStack {
                // Status bar at top
                HStack {
                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.red.opacity(0.8))
                            .cornerRadius(8)
                    } else if let date = lastSaveDate {
                        TimelineView(.periodic(from: Date(), by: 60)) { _ in
                            Text("Saved \(date.relativeTimeString())")
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Color.green.opacity(0.8))
                                .cornerRadius(8)
                        }
                    }
                    Spacer()

                    if hasFrontAndBack {
                        Button(action: flipCamera) {
                            Image(systemName: "camera.rotate")
                                .font(.title2)
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        .disabled(model.isRecording)
                    }
                }
                .padding()

                Spacer()

                // Recording duration in center when recording
                if model.isRecording {
                    Text(formatDuration(model.recordingDuration))
                        .font(.system(size: 48, weight: .light, design: .monospaced))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                }

                Spacer()

                // Lens picker
                if camerasForCurrentPosition.count > 1 {
                    HStack {
                        ForEach(camerasForCurrentPosition, id: \.uniqueID) { device in
                            lensButton(for: device)
                        }
                    }
                    .padding(.bottom, 20)
                }

                // Record button
                Button(action: toggleRecording) {
                    ZStack {
                        // Outer circle
                        Circle()
                            .stroke(Color.white, lineWidth: 3)
                            .frame(width: 80, height: 80)

                        // Inner shape - circle when not recording, square when recording
                        if model.isRecording {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.red)
                                .frame(width: 36, height: 36)
                        } else {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 70, height: 70)
                        }
                    }
                }
                .disabled(model.isSaving)
                .opacity(model.isSaving ? 0.5 : 1.0)
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            model.configure(cloudManager: cloudManager)
            Task {
                if await !AVCaptureDevice.requestAccess(for: .video) {
                    errorMessage = "Camera access denied. Enable in Settings > Privacy & Security > Camera"
                    return
                }
                if await !AVCaptureDevice.requestAccess(for: .audio) {
                    errorMessage = "Microphone access denied. Enable in Settings > Privacy & Security > Microphone"
                    return
                }
                discoverCameras()
                // Get initial device (wide-angle back, or first available)
                if let initial = camerasForCurrentPosition.first(where: {
                    $0.deviceType == .builtInWideAngleCamera
                }) ?? camerasForCurrentPosition.first {
                    currentDevice = initial
                    await model.setupCamera(with: initial)
                }
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.stop()
        }
        .onChange(of: model.lastSaveDate) { _, date in
            lastSaveDate = date
        }
        .onChange(of: model.errorMessage) { _, error in
            errorMessage = error
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                model.handleBackground()
            }
        }
    }

    private func toggleRecording() {
        if model.isRecording {
            model.stopRecording()
        } else {
            model.startRecording()
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func discoverCameras() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInTelephotoCamera,
                          .builtInUltraWideCamera],
            mediaType: .video,
            position: .unspecified
        )
        availableCameras = discovery.devices
    }

    var camerasForCurrentPosition: [AVCaptureDevice] {
        availableCameras.filter { $0.position == currentPosition }
    }

    var hasFrontAndBack: Bool {
        availableCameras.contains { $0.position == .front } &&
        availableCameras.contains { $0.position == .back }
    }

    private func flipCamera() {
        currentPosition = (currentPosition == .back) ? .front : .back
        // Switch to wide-angle (1x) on the new side
        if let wideAngle = camerasForCurrentPosition.first(where: {
            $0.deviceType == .builtInWideAngleCamera
        }) ?? camerasForCurrentPosition.first {
            switchCamera(to: wideAngle)
        }
    }

    private func switchCamera(to device: AVCaptureDevice) {
        model.switchCamera(to: device)
        currentDevice = device
    }

    private func lensLabel(for device: AVCaptureDevice) -> String {
        switch device.deviceType {
        case .builtInUltraWideCamera: return "0.5x"
        case .builtInWideAngleCamera: return "1x"
        case .builtInTelephotoCamera: return "2x"
        default: return "1x"
        }
    }

    @ViewBuilder
    private func lensButton(for device: AVCaptureDevice) -> some View {
        if currentDevice == device {
            Button(lensLabel(for: device)) {
                switchCamera(to: device)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isRecording)
        } else {
            Button(lensLabel(for: device)) {
                switchCamera(to: device)
            }
            .buttonStyle(.bordered)
            .disabled(model.isRecording)
        }
    }
}

// MARK: - Camera Preview View

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let device: AVCaptureDevice?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.bind(device: device, layer: view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.bind(device: device, layer: uiView.previewLayer)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Drives the preview layer's rotation from `AVCaptureDevice.RotationCoordinator`, which
    /// tracks the physical device orientation and is KVO-observable. This avoids both the
    /// manual orientation→angle mapping and any dependence on `updateUIView` firing at the
    /// right moment. The recorded file's orientation is handled separately at record start.
    final class Coordinator {
        private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var observation: NSKeyValueObservation?
        private weak var boundDevice: AVCaptureDevice?

        func bind(device: AVCaptureDevice?, layer: AVCaptureVideoPreviewLayer) {
            guard let device, device !== boundDevice else { return }
            boundDevice = device

            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
            rotationCoordinator = coordinator
            apply(coordinator.videoRotationAngleForHorizonLevelPreview, to: layer)

            observation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelPreview, options: [.new]
            ) { [weak self, weak layer] _, change in
                guard let layer, let angle = change.newValue else { return }
                DispatchQueue.main.async { self?.apply(angle, to: layer) }
            }
        }

        private func apply(_ angle: CGFloat, to layer: AVCaptureVideoPreviewLayer) {
            guard let connection = layer.connection,
                  connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }
    }

    class PreviewView: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

// MARK: - Video Recording Model

@MainActor
class VideoRecordingModel: ObservableObject {
    nonisolated(unsafe) let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let outputQueue = DispatchQueue(label: "io.bvf.bideo.output")

    private var secureRecorder: SecureVideoRecorder?
    private var cloudManager: iCloudManager?
    private var durationCancellable: AnyCancellable?
    nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
    nonisolated(unsafe) private var terminateObserver: NSObjectProtocol?
    nonisolated(unsafe) private var captureDevice: AVCaptureDevice?
    nonisolated(unsafe) private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?

    @Published var isRecording = false
    @Published var isSaving = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var lastSaveDate: Date?
    @Published var errorMessage: String?
    @Published var isConfigured = false

    private var currentContext: PushEncryptionContext?
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

    func configure(cloudManager: iCloudManager) {
        self.cloudManager = cloudManager
        setupInterruptionObserver()
        setupTerminateObserver()
    }

    func setupCamera(with videoDevice: AVCaptureDevice) async {
        if isConfigured {
            start()
            return
        }

        guard session.inputs.isEmpty else { return }

        configureSession(videoDevice: videoDevice)
    }

    private func configureSession(videoDevice: AVCaptureDevice) {
        session.beginConfiguration()
        session.sessionPreset = .high

        // Add video input
        guard let videoInput = try? AVCaptureDeviceInput(device: videoDevice) else {
            errorMessage = "Cannot access camera"
            session.commitConfiguration()
            return
        }

        if session.canAddInput(videoInput) {
            session.addInput(videoInput)
        }

        self.captureDevice = videoDevice
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: videoDevice, previewLayer: nil)

        // Add audio input
        guard let audioDevice = AVCaptureDevice.default(for: .audio),
              let audioInput = try? AVCaptureDeviceInput(device: audioDevice) else {
            errorMessage = "Cannot access microphone"
            session.commitConfiguration()
            return
        }

        if session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        // Add video output
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        // Add audio output
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }

        session.commitConfiguration()
        isConfigured = true

        start()
    }

    func switchCamera(to device: AVCaptureDevice) {
        session.beginConfiguration()
        // Remove existing video input
        if let currentInput = session.inputs.first(where: {
            ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.video) == true
        }) as? AVCaptureDeviceInput {
            session.removeInput(currentInput)
        }
        // Add new video input
        if let newInput = try? AVCaptureDeviceInput(device: device) {
            session.addInput(newInput)
            captureDevice = device
            rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        }
        session.commitConfiguration()
    }

    func start() {
        guard isConfigured else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func stop() {
        if isRecording {
            stopRecording()
        }
        session.stopRunning()
    }

    /// Angle (degrees) the capture connection should rotate to keep the horizon level.
    /// Fixed at record start; the whole clip stays in the orientation it began in.
    private func captureRotationAngle() -> CGFloat {
        rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
    }

    func startRecording() {
        guard let cloudManager = cloudManager,
              let publicKeyURL = cloudManager.sharedPublicKeyURL,
              let folderURL = cloudManager.appFolderURL else {
            errorMessage = "iCloud not configured"
            return
        }

        // Lock the recording orientation now and rotate the delivered buffers upright, so the
        // recorder writes correctly-oriented frames without needing a track transform.
        let angle = captureRotationAngle()
        if let connection = videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }

        guard let videoDimensions = getVideoDimensions(rotationAngle: angle) else {
            errorMessage = "Cannot determine video dimensions"
            return
        }

        do {
            let context = try PushEncryptionContext(publicKeyURL: publicKeyURL, to: folderURL, suffix: "mp4")
            currentContext = context

            let recorder = SecureVideoRecorder()
            try recorder.start(
                encryptionContext: context,
                width: videoDimensions.width,
                height: videoDimensions.height
            )

            videoOutput.setSampleBufferDelegate(recorder, queue: outputQueue)
            audioOutput.setSampleBufferDelegate(recorder, queue: outputQueue)

            secureRecorder = recorder
            isRecording = true
            recordingDuration = 0
            errorMessage = nil

            durationCancellable = recorder.$duration
                .receive(on: DispatchQueue.main)
                .sink { [weak self] duration in
                    self?.recordingDuration = duration
                }

            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()

        } catch {
            currentContext = nil
            errorMessage = "Recording failed: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard let recorder = secureRecorder else { return }

        durationCancellable?.cancel()
        durationCancellable = nil

        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        audioOutput.setSampleBufferDelegate(nil, queue: nil)

        do {
            try recorder.stop()
            secureRecorder = nil

            currentContext = nil
            isRecording = false
            lastSaveDate = Date()

            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)

        } catch {
            errorMessage = "Stop recording failed: \(error.localizedDescription)"
            isRecording = false
            secureRecorder = nil
            currentContext = nil

            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)
        }
    }

    func handleBackground() {
        backgroundTaskId = UIApplication.shared.beginBackgroundTask { [weak self] in
            Task { @MainActor in
                self?.endBackgroundTaskIfNeeded()
            }
        }
        // Video can't record in the background: stop and finalize now. stopRecording()
        // commits the file synchronously, so it lands in the iCloud folder before the app
        // suspends; the background task only has to cover that brief finalize.
        if isRecording {
            stopRecording()
        }
        endBackgroundTaskIfNeeded()
    }

    private func endBackgroundTaskIfNeeded() {
        if backgroundTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
            backgroundTaskId = .invalid
        }
    }

    /// Native sensor dimensions, swapped when the applied rotation is a quarter-turn so they
    /// match the buffers the (rotated) capture connection now delivers.
    private func getVideoDimensions(rotationAngle: CGFloat) -> (width: Int32, height: Int32)? {
        guard let videoInput = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput })
            .first(where: { $0.device.hasMediaType(.video) }) else {
            return nil
        }

        let formatDescription = videoInput.device.activeFormat.formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)

        if rotationAngle == 90 || rotationAngle == 270 {
            return (width: dimensions.height, height: dimensions.width)
        }
        return (width: dimensions.width, height: dimensions.height)
    }

    private func setupTerminateObserver() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                if self?.isRecording == true {
                    self?.stopRecording()
                }
            }
        }
    }

    private func setupInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
            }

            Task { @MainActor in
                if type == .began {
                    // Interruption began (phone call, Siri, etc.) - save recording cleanly
                    self?.stopRecording()
                }
            }
        }
    }

    deinit {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = terminateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

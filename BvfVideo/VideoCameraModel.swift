import AVFoundation
import AppKit
import Combine
import BvfAppKitDecrypt
import os.log

/// Owns the `AVCaptureSession` (selectable camera + default mic) and vends sample buffers to a
/// delegate. Plaintext never leaves this object as a file — buffers go straight to
/// `SecureVideoRecorder`, which encodes and encrypts them in memory.
final class VideoCameraModel: NSObject, ObservableObject, @unchecked Sendable {
    private let logger = Logger(subsystem: "io.bvf.bideo", category: "camera")
    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) private let videoOutput = AVCaptureVideoDataOutput()
    nonisolated(unsafe) private let audioOutput = AVCaptureAudioDataOutput()
    private let videoOutputQueue = DispatchQueue(label: "io.bvf.bideo.camera.video-output")
    private let audioOutputQueue = DispatchQueue(label: "io.bvf.bideo.camera.audio-output")

    @Published var isConfigured = false
    @Published var isSessionRunning = false
    @Published var responseMessage: ResponseMessage?
    @Published var availableDevices: [AVCaptureDevice] = []
    @Published var selectedDeviceUniqueID: String?

    nonisolated(unsafe) weak var sampleBufferDelegate: (any AVCaptureVideoDataOutputSampleBufferDelegate & AVCaptureAudioDataOutputSampleBufferDelegate)?

    private var sessionRunningObservation: NSKeyValueObservation?

    override init() {
        super.init()
    }

    func setupCamera() async {
        logger.info("Setup camera started")

        if isConfigured {
            start()
            return
        }

        guard session.inputs.isEmpty else { return }

        if await !AVCaptureDevice.requestAccess(for: .video) {
            await MainActor.run {
                responseMessage = ResponseMessage("Camera access denied. Enable in System Settings > Privacy & Security > Camera", type: .error)
            }
            return
        }

        if await !AVCaptureDevice.requestAccess(for: .audio) {
            await MainActor.run {
                responseMessage = ResponseMessage("Microphone access denied. Enable in System Settings > Privacy & Security > Microphone", type: .error)
            }
            return
        }

        configureSession()
        logger.info("Setup camera completed")
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        // Video input — built-in wide-angle (or external) camera.
        let videoDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )

        let videoDevices = videoDiscovery.devices
        guard let videoDevice = videoDevices.first else {
            responseMessage = ResponseMessage("No camera found", type: .error)
            session.commitConfiguration()
            return
        }

        availableDevices = videoDevices
        selectedDeviceUniqueID = videoDevice.uniqueID

        do {
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            } else {
                responseMessage = ResponseMessage("Cannot add camera input to session", type: .error)
                session.commitConfiguration()
                return
            }
        } catch {
            responseMessage = ResponseMessage("Camera input error: \(error.localizedDescription)", type: .error)
            session.commitConfiguration()
            return
        }

        // Audio input — default microphone.
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            responseMessage = ResponseMessage("No microphone found", type: .error)
            session.commitConfiguration()
            return
        }

        do {
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if session.canAddInput(audioInput) {
                session.addInput(audioInput)
            } else {
                responseMessage = ResponseMessage("Cannot add microphone input to session", type: .error)
                session.commitConfiguration()
                return
            }
        } catch {
            responseMessage = ResponseMessage("Microphone input error: \(error.localizedDescription)", type: .error)
            session.commitConfiguration()
            return
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }

        session.commitConfiguration()
        isConfigured = true

        sessionRunningObservation = session.observe(\.isRunning, options: [.new]) { [weak self] _, change in
            guard let self = self, let isRunning = change.newValue else { return }
            Task { @MainActor in
                self.isSessionRunning = isRunning
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func setSampleBufferDelegate(_ delegate: (any AVCaptureVideoDataOutputSampleBufferDelegate & AVCaptureAudioDataOutputSampleBufferDelegate)?) {
        sampleBufferDelegate = delegate
        videoOutput.setSampleBufferDelegate(delegate, queue: videoOutputQueue)
        audioOutput.setSampleBufferDelegate(delegate, queue: audioOutputQueue)
    }

    func removeSampleBufferDelegate() {
        sampleBufferDelegate = nil
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        audioOutput.setSampleBufferDelegate(nil, queue: nil)
    }

    func start() {
        guard isConfigured else { return }
        logger.info("Starting session")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func stop() {
        logger.info("Stopping session")
        session.stopRunning()
    }

    /// Swap the session's video input to the camera with `uniqueID`. Mic input is untouched.
    func switchCamera(to uniqueID: String) {
        guard isConfigured, uniqueID != selectedDeviceUniqueID else { return }
        guard let device = availableDevices.first(where: { $0.uniqueID == uniqueID }) else { return }

        session.beginConfiguration()
        for input in session.inputs {
            if let deviceInput = input as? AVCaptureDeviceInput, deviceInput.device.hasMediaType(.video) {
                session.removeInput(deviceInput)
            }
        }

        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                selectedDeviceUniqueID = uniqueID
            } else {
                responseMessage = ResponseMessage("Cannot switch to selected camera", type: .error)
            }
        } catch {
            responseMessage = ResponseMessage("Camera switch error: \(error.localizedDescription)", type: .error)
        }
        session.commitConfiguration()
    }

    /// Dimensions of the active video format, used to size the encoder.
    var videoDimensions: CMVideoDimensions? {
        guard let device = session.inputs
            .compactMap({ $0 as? AVCaptureDeviceInput })
            .first(where: { $0.device.hasMediaType(.video) })?
            .device
        else { return nil }
        return CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
    }
}

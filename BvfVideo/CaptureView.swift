import SwiftUI
import AVFoundation
import BvfAppKitDecrypt

struct CaptureView: View {
    @Environment(FileAccessManager.self) private var fileAccessManager
    @StateObject private var camera = VideoCameraModel()
    @StateObject private var recorder = SecureVideoRecorder()

    private var publicKeyURL: URL? { fileAccessManager.capturePublicKeyURL }
    private var folderURL: URL? { fileAccessManager.captureFolderURL }

    private var isReady: Bool {
        publicKeyURL != nil && folderURL != nil
    }

    @State private var responseMessage: ResponseMessage?
    @State private var currentContext: PushEncryptionContext?

    var body: some View {
        ZStack {
            CameraPreviewView(session: camera.session)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerView
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                    .padding(.top, 8)

                Spacer()

                if recorder.isRecording {
                    Text(formatDuration(recorder.duration))
                        .font(.system(size: 24, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.8))
                        .cornerRadius(8)
                        .padding(.bottom, 20)
                }

                Button(action: toggleRecording) {
                    ZStack {
                        if recorder.isRecording {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.red)
                                .frame(width: 40, height: 40)
                        } else {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 60, height: 60)
                        }

                        Circle()
                            .stroke(Color.white, lineWidth: 3)
                            .frame(width: 80, height: 80)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!isReady || !camera.isSessionRunning)
                .keyboardShortcut(.space, modifiers: [])
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            validateConfiguration()
            Task {
                await camera.setupCamera()
            }
        }
        .onDisappear {
            if recorder.isRecording {
                stopRecording()
            }
            camera.stop()
        }
        .onChange(of: folderURL) { _, _ in validateConfiguration() }
        .onChange(of: publicKeyURL) { _, _ in validateConfiguration() }
        .onChange(of: recorder.error?.localizedDescription) { _, message in
            if let message {
                responseMessage = ResponseMessage(message, type: .error)
            }
        }
    }

    private func validateConfiguration() {
        responseMessage = fileAccessManager.validateCaptureConfiguration(folderName: "video folder")
        camera.responseMessage = responseMessage
    }

    private var headerView: some View {
        HStack {
            ReadyIndicatorView(isReady: isReady)

            if camera.isConfigured && !camera.isSessionRunning {
                Text("Starting camera…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if recorder.isRecording {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("Recording")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            } else if let message = responseMessage ?? camera.responseMessage {
                Text(message.text)
                    .font(.caption)
                    .foregroundColor(message.type.color)
                    .lineLimit(2)
            }

            Spacer()

            if camera.availableDevices.count > 1 {
                Picker("Camera", selection: Binding(
                    get: { camera.selectedDeviceUniqueID ?? "" },
                    set: { camera.switchCamera(to: $0) }
                )) {
                    ForEach(camera.availableDevices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 200)
                .disabled(recorder.isRecording)
            }

            Button(action: toggleRecording) {
                Label(
                    recorder.isRecording ? "Stop" : "Record",
                    systemImage: recorder.isRecording ? "stop.fill" : "record.circle"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? .red : .accentColor)
            .disabled(!isReady || !camera.isSessionRunning)
            .keyboardShortcut("S", modifiers: .command)
        }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard let publicKeyURL, let folderURL else {
            responseMessage = ResponseMessage("Missing folder or public key", type: .error)
            return
        }

        let width: Int32
        let height: Int32
        if let dimensions = camera.videoDimensions {
            width = dimensions.width
            height = dimensions.height
        } else {
            width = 1920
            height = 1080
        }

        do {
            let context = try PushEncryptionContext(publicKeyURL: publicKeyURL, to: folderURL, suffix: "mp4")
            currentContext = context

            camera.setSampleBufferDelegate(recorder)
            try recorder.start(encryptionContext: context, width: width, height: height)
            responseMessage = nil
        } catch {
            camera.removeSampleBufferDelegate()
            currentContext = nil
            responseMessage = ResponseMessage("Failed to start recording: \(error.localizedDescription)", type: .error)
        }
    }

    private func stopRecording() {
        camera.removeSampleBufferDelegate()

        do {
            try recorder.stop()
            currentContext = nil
            responseMessage = ResponseMessage("Saved at \(Date().timeString)", type: .success)
        } catch {
            responseMessage = ResponseMessage("Failed to stop recording: \(error.localizedDescription)", type: .error)
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let tenths = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }
}

// MARK: - Camera Preview (macOS)

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    class PreviewView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = AVCaptureVideoPreviewLayer()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }
}

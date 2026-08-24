import Combine
import Foundation
import UniformTypeIdentifiers
@preconcurrency import AVFoundation
import BvfAppKit

/// Records camera + mic to an encrypted fragmented-MP4 file. Plaintext video/audio never
/// touches disk: `AVAssetWriter` in delegate-segment mode muxes H.264 + AAC entirely in
/// memory, and each emitted segment is streamed through `PushEncryptionContext`, which writes
/// only ciphertext. The concatenation of the init segment followed by every media segment,
/// in delivery order, is a valid fMP4 file.
///
/// Threading:
/// - Video and audio buffers arrive on two separate capture queues; each media type has its
///   own `AVAssetWriterInput`, so concurrent appends are safe (never two threads to one input).
/// - The session is started once, under `stateLock`, off the first buffer of either type.
/// - `didOutputSegmentData` may arrive on an arbitrary queue → all encryption writes are
///   serialized on `encryptionQueue` (FIFO preserves init-then-media segment order).
final class SecureVideoRecorder: NSObject, ObservableObject, @unchecked Sendable {
    @Published var isRecording = false
    @Published var duration: TimeInterval = 0
    @Published var error: Error?

    private let encryptionQueue = DispatchQueue(label: "io.bvf.video.encryption")
    private let stateLock = NSLock()

    nonisolated(unsafe) private var writer: AVAssetWriter?
    nonisolated(unsafe) private var videoInput: AVAssetWriterInput?
    nonisolated(unsafe) private var audioInput: AVAssetWriterInput?
    nonisolated(unsafe) private var encryptionContext: PushEncryptionContext?

    nonisolated(unsafe) private var isWriting = false
    nonisolated(unsafe) private var sessionStarted = false

    nonisolated(unsafe) private var durationTimer: Timer?

    override init() {
        super.init()
    }

    deinit {
        durationTimer?.invalidate()
    }

    // MARK: - Lifecycle

    /// Configure the in-memory writer and begin accepting buffers. The session's timeline is
    /// started lazily on the first sample buffer (see `captureOutput`).
    func start(encryptionContext: PushEncryptionContext, width: Int32, height: Int32) throws {
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 1.0, preferredTimescale: 1)
        writer.delegate = self

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(width),
            AVVideoHeightKey: Int(height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ])
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw RecorderError.cannotAddInputs
        }
        writer.add(videoInput)
        writer.add(audioInput)

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.encryptionContext = encryptionContext
        self.sessionStarted = false
        self.isWriting = true

        let recordStart = Date()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.duration = Date().timeIntervalSince(recordStart)
            }
        }

        Task { @MainActor in
            self.isRecording = true
            self.duration = 0
        }
    }

    /// Finish the writer (which flushes the final segment through the delegate first), then
    /// commit the ciphertext. FIFO on `encryptionQueue` guarantees the last segment write is
    /// enqueued before `finish()`.
    func stop() throws {
        stateLock.lock()
        isWriting = false
        let started = sessionStarted
        stateLock.unlock()

        durationTimer?.invalidate()
        durationTimer = nil

        Task { @MainActor in
            self.isRecording = false
            self.duration = 0
        }

        defer { clearWriter() }

        guard let writer, let videoInput, let audioInput else {
            try finishEncryptionSync()
            return
        }

        guard started, writer.status == .writing else {
            // No frames were ever appended — nothing valid to commit.
            writer.cancelWriting()
            try finishEncryptionSync()
            return
        }

        // Finalize synchronously so that, as with the audio recorder, `stop()` does not
        // return until the encrypted file has been committed into the iCloud folder. On
        // iOS this is what keeps a recording alive across an immediate suspend: if we
        // returned early, the final segment flush and the staging→container commit could
        // be dropped when the app is suspended, leaving the clip stranded in staging.
        videoInput.markAsFinished()
        audioInput.markAsFinished()

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting {
            finished.signal()
        }
        finished.wait()

        try finishEncryptionSync()
    }

    /// Drain any in-flight segment writes (FIFO on `encryptionQueue`), then commit the
    /// encryption context on that same queue so the commit is serialized after the last
    /// `didOutputSegmentData` write. Throws if the commit fails.
    private func finishEncryptionSync() throws {
        var thrown: Error?
        encryptionQueue.sync {
            do {
                _ = try self.encryptionContext?.finish()
            } catch {
                thrown = error
            }
            self.encryptionContext = nil
        }
        if let thrown { throw thrown }
    }

    private func clearWriter() {
        writer = nil
        videoInput = nil
        audioInput = nil
    }

    // MARK: - Sample buffer intake

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard isWriting, let writer else { return }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let mediaType = CMFormatDescriptionGetMediaType(formatDescription)

        // Start the session once, off the first buffer of either track, under the lock.
        stateLock.lock()
        if !sessionStarted {
            // Mark started up front so a racing buffer on the other capture queue can never
            // call startWriting() a second time (a second call on a failed writer raises).
            sessionStarted = true
            let firstPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            // initialSegmentStartTime MUST be set before startWriting() when a finite
            // preferredOutputSegmentInterval is in use; otherwise startWriting() fails.
            writer.initialSegmentStartTime = firstPTS
            guard writer.startWriting() else {
                isWriting = false
                let startError = writer.error
                stateLock.unlock()
                if let startError { Task { @MainActor in self.error = startError } }
                return
            }
            writer.startSession(atSourceTime: firstPTS)
        }
        stateLock.unlock()

        guard writer.status == .writing else { return }

        switch mediaType {
        case kCMMediaType_Video:
            if let videoInput, videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }
        case kCMMediaType_Audio:
            if let audioInput, audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }
        default:
            break
        }
    }
}

// MARK: - Capture delegates

extension SecureVideoRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handle(sampleBuffer)
    }
}

// MARK: - Writer delegate (segments → encryption)

extension SecureVideoRecorder: AVAssetWriterDelegate {
    func assetWriter(_ writer: AVAssetWriter,
                     didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?) {
        encryptionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.encryptionContext?.write(segmentData)
            } catch {
                Task { @MainActor in self.error = error }
            }
        }
    }
}

enum RecorderError: LocalizedError {
    case cannotAddInputs

    var errorDescription: String? {
        switch self {
        case .cannotAddInputs:
            return "Failed to configure video/audio inputs"
        }
    }
}

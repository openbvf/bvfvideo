import Speech
import AVFoundation
import UniformTypeIdentifiers

/// Transcribes the audio track of an in-memory video (fragmented MP4) with the on-device
/// `SpeechAnalyzer`. Plaintext never touches disk: the decrypted movie is served to
/// `AVAssetReader` through the same custom-scheme `AVAssetResourceLoaderDelegate` used for
/// playback (see `DataResourceLoaderDelegate` in InMemoryVideoPlayer.swift), and the audio
/// track is decoded/resampled to 16 kHz Int16 mono PCM — the same format BvfAudio feeds the
/// analyzer. Intentionally duplicated from BvfAudio's `TranscriptionService` rather than
/// shared; only the decoder differs (AVAssetReader here vs. ExtAudioFile there).
@available(macOS 26.0, *)
final class VideoTranscriptionService {
    private let loaderQueue = DispatchQueue(label: "io.bvf.video.transcription.resourceloader")

    func transcribe(videoData: Data) async throws -> String {
        let locale = Locale(identifier: "en-US")
        let preset = SpeechTranscriber.Preset(
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        let transcriber = SpeechTranscriber(locale: locale, preset: preset)

        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await downloader.downloadAndInstall()
        }

        // Serve the decrypted movie from RAM via a custom scheme so AVAssetReader can read it
        // without a file on disk.
        let loaderDelegate = DataResourceLoaderDelegate(data: videoData, contentType: UTType.mpeg4Movie.identifier)
        let asset = AVURLAsset(url: URL(string: "bvfvideo://transcribe.mp4")!)
        asset.resourceLoader.setDelegate(loaderDelegate, queue: loaderQueue)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else { return "" }

        // 16 kHz Int16 mono PCM — matches the format BvfAudio feeds the analyzer. AVAssetReader
        // performs the AAC decode, downmix, and resample.
        let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        )!
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw VideoTranscriptionError.readerFailed(nil)
        }
        reader.add(output)
        guard reader.startReading() else {
            throw VideoTranscriptionError.readerFailed(reader.error)
        }

        let (inputStream, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        Task { try await analyzer.start(inputSequence: inputStream) }

        // Consume results concurrently to avoid backpressure deadlock.
        let resultTask = Task {
            var r = ""
            for try await response in transcriber.results {
                if response.isFinal {
                    r.append(response.text.description)
                }
            }
            return r
        }

        var totalFrames = 0
        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            if let buffer = makePCMBuffer(from: sampleBuffer, format: pcmFormat) {
                totalFrames += Int(buffer.frameLength)
                inputBuilder.yield(AnalyzerInput(buffer: buffer))
            }
            CMSampleBufferInvalidate(sampleBuffer)
        }

        inputBuilder.finish()

        if reader.status == .failed {
            resultTask.cancel()
            throw VideoTranscriptionError.readerFailed(reader.error)
        }

        if totalFrames == 0 {
            resultTask.cancel()
            return ""
        }

        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await resultTask.value
    }

    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buffer
    }
}

enum VideoTranscriptionError: LocalizedError {
    case readerFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .readerFailed(let error):
            return "Failed to read video audio: \(error?.localizedDescription ?? "unknown error")"
        }
    }
}

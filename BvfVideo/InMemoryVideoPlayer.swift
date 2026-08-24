import AVFoundation
import AVKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Plays decrypted video from an in-memory `Data` buffer with no file on disk. Uses the
/// canonical `AVURLAsset` custom-scheme + `AVAssetResourceLoaderDelegate` path (still the
/// supported approach on macOS 26 — there is no `AVAsset(data:)`). The whole file lives in RAM,
/// so `isEntireLengthAvailableOnDemand` is set to avoid the resource-loader memory blow-up.
@MainActor
final class InMemoryVideoPlayer {
    let player: AVPlayer

    private let loaderDelegate: DataResourceLoaderDelegate
    private let loaderQueue = DispatchQueue(label: "io.bvf.video.resourceloader")
    private var endObserver: NSObjectProtocol?

    /// Called on the main actor when playback reaches the end of the item.
    var onPlaybackEnded: (() -> Void)?

    init(data: Data) {
        loaderDelegate = DataResourceLoaderDelegate(data: data, contentType: UTType.mpeg4Movie.identifier)

        let asset = AVURLAsset(url: URL(string: "bvfvideo://recording.mp4")!)
        asset.resourceLoader.setDelegate(loaderDelegate, queue: loaderQueue)

        let item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onPlaybackEnded?()
            }
        }
    }

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    /// Resolve the asset duration asynchronously; returns 0 if unknown/indefinite.
    func loadDuration() async -> TimeInterval {
        guard let item = player.currentItem else { return 0 }
        do {
            let duration = try await item.asset.load(.duration)
            let seconds = duration.seconds
            return seconds.isFinite ? seconds : 0
        } catch {
            return 0
        }
    }

    var currentTime: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func stop() {
        player.pause()
        player.seek(to: .zero)
    }

    func seek(to time: TimeInterval) {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// Serves a fully-in-memory `Data` buffer to `AVPlayer` via a custom URL scheme.
final class DataResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let data: Data
    private let contentType: String

    init(data: Data, contentType: String) {
        self.data = data
        self.contentType = contentType
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let infoRequest = loadingRequest.contentInformationRequest {
            infoRequest.contentType = contentType
            infoRequest.contentLength = Int64(data.count)
            infoRequest.isByteRangeAccessSupported = true
            infoRequest.isEntireLengthAvailableOnDemand = true
        }

        if let dataRequest = loadingRequest.dataRequest {
            let start = Int(dataRequest.currentOffset)
            guard start <= data.count else {
                loadingRequest.finishLoading()
                return true
            }
            let end: Int
            if dataRequest.requestsAllDataToEndOfResource {
                end = data.count
            } else {
                end = min(Int(dataRequest.requestedOffset) + dataRequest.requestedLength, data.count)
            }
            if start < end {
                dataRequest.respond(with: data.subdata(in: start..<end))
            }
        }

        loadingRequest.finishLoading()
        return true
    }
}

/// Bridges `AVPlayerLayer` into SwiftUI — no AVKit control chrome, no fullscreen button.
struct VideoPlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerNSView {
        let view = PlayerLayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerNSView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }

    /// Layer-backed view that hosts the `AVPlayerLayer` as a sublayer. Replacing the view's
    /// backing layer with an `AVPlayerLayer` (layer-hosting) renders unreliably inside a
    /// SwiftUI `NSViewRepresentable`; adding it as a sublayer is the robust pattern.
    final class PlayerLayerNSView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            if playerLayer.superlayer == nil {
                layer?.addSublayer(playerLayer)
            }
            playerLayer.frame = bounds
        }
    }
}

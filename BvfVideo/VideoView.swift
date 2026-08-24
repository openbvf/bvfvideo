import SwiftUI
import BvfAppKitDecrypt
import UniformTypeIdentifiers
import AVFoundation
import AppKit

struct VideoView: View {
    @Environment(FileAccessManager.self) var fileAccessManager
    @Environment(AppSettings.self) var appSettings
    @Environment(SyncManager.self) var syncManager
    @Environment(iCloudManager.self) var cloudManager
    @State private var viewModel: VideoViewModel?

    @State private var showTagSheet = false
    @State private var isFullscreen = false

    nonisolated func isVideoFile(_ url: URL) -> Bool {
        guard let uttype = UTType(filenameExtension: url.pathExtension) else { return false }
        let supportedTypes = AVURLAsset.audiovisualTypes()
        return supportedTypes.contains { $0.rawValue == uttype.identifier } && uttype.conforms(to: .movie)
    }

    var body: some View {
        Group {
            if let viewModel {
                VStack {
                    DateRangeRowView(
                        startDate: Binding(get: { viewModel.startDate }, set: { viewModel.startDate = $0 }),
                        endDate: Binding(get: { viewModel.endDate }, set: { viewModel.endDate = $0 }),
                        selectedPreset: Binding(get: { viewModel.selectedPreset }, set: { viewModel.selectedPreset = $0 }),
                        isReady: viewModel.folderURL != nil && viewModel.publicKeyURL != nil,
                        isLoading: viewModel.isLoading || viewModel.isDecrypting,
                        responseMessage: viewModel.responseMessage,
                        setupErrorMessage: nil,
                        onDecrypt: {
                            await viewModel.loadEntries()
                        }
                    )

                    HSplitView {
                        List {
                            ForEach(viewModel.groupedDates, id: \.day) { day, dates in
                                Section {
                                    ForEach(dates, id: \.self) { date in
                                        VideoRowView(
                                            date: date,
                                            isPlaying: viewModel.currentlyPlayingDate == date && viewModel.isPlaying,
                                            onTap: { viewModel.play(date: date) },
                                            onTranscribe: {
                                                let dates = viewModel.selectedDates.contains(date)
                                                    ? Array(viewModel.selectedDates)
                                                    : [date]
                                                viewModel.startTranscription(dates: dates)
                                            },
                                            viewModel: viewModel
                                        )
                                        .selectableItem(date: date, isSelected: viewModel.selectedDates.contains(date)) {
                                            viewModel.handleSelection(date, in: viewModel.filteredDates)
                                        }
                                    }
                                } header: {
                                    Text(day.dayWithWeekdayString)
                                }
                            }
                        }
                        .frame(minWidth: 250, idealWidth: 280)

                        VideoPlayerPane(viewModel: viewModel, isFullscreen: $isFullscreen)
                            .frame(minWidth: 400)
                            .layoutPriority(1)
                    }
                }
                .browseToolbar(
                    viewModel: viewModel,
                    configuration: BrowseToolbarConfiguration(
                        clearHelpText: "Clear all videos",
                        importFileFilter: isVideoFile
                    ),
                    showTagSheet: $showTagSheet
                )
                .padding()
                .browseModals(
                    viewModel: viewModel,
                    showTagSheet: $showTagSheet
                )
                .toolbar {
                    ToolbarItem {
                        if #available(macOS 26.0, *) {
                            if viewModel.isTranscribing {
                                Button(action: { viewModel.cancelTranscription() }) {
                                    Label("Cancel Transcription", systemImage: "xmark.circle.fill")
                                }
                                .help("Cancel transcription")
                            } else {
                                Button(action: {
                                    viewModel.startTranscription(dates: Array(viewModel.selectedDates))
                                }) {
                                    Label("Transcribe to Bedit", systemImage: "text.bubble")
                                }
                                .disabled(viewModel.selectedDates.isEmpty)
                                .help("Transcribe to Bedit")
                            }
                        }
                    }
                }
                .background(FullscreenPresenter(viewModel: viewModel, isFullscreen: $isFullscreen))
            } else {
                ProgressView()
            }
        }
        .task {
            if viewModel == nil {
                viewModel = VideoViewModel(fileAccessManager: fileAccessManager, appSettings: appSettings, syncManager: syncManager, cloudManager: cloudManager)
            }
        }
    }
}

// MARK: - Player pane

private struct VideoPlayerPane: View {
    var viewModel: VideoViewModel
    @Binding var isFullscreen: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let player = viewModel.player {
                VideoPlayerLayerView(player: player.player)
                    // Re-create the inline layer when returning from fullscreen so the AVPlayer
                    // re-attaches its output to it.
                    .id("\(String(describing: viewModel.currentlyPlayingDate))-\(isFullscreen)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .cornerRadius(8)

                VideoTransportView(
                    isPlaying: viewModel.isPlaying,
                    currentTime: viewModel.currentTime,
                    duration: viewModel.duration,
                    onTogglePlayPause: { viewModel.togglePlayPause() },
                    onSeek: { viewModel.seek(to: $0) },
                    onSeekRelative: { delta in
                        let target = max(0, min(viewModel.duration, viewModel.currentTime + delta))
                        viewModel.seek(to: target)
                    },
                    isFullscreen: false,
                    onToggleFullscreen: { isFullscreen = true }
                )
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "video")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Select a video to play")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }
}

// MARK: - Fullscreen

/// Content hosted in the dedicated fullscreen window: just the video, with the transport
/// overlaid and auto-hiding after the pointer goes idle (revealed on movement).
private struct FullscreenVideoView: View {
    var viewModel: VideoViewModel
    let onExit: () -> Void

    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?

    private static let idleInterval: Duration = .seconds(2.5)

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black

            if let player = viewModel.player {
                VideoPlayerLayerView(player: player.player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VideoTransportView(
                    isPlaying: viewModel.isPlaying,
                    currentTime: viewModel.currentTime,
                    duration: viewModel.duration,
                    onTogglePlayPause: { viewModel.togglePlayPause() },
                    onSeek: { viewModel.seek(to: $0) },
                    onSeekRelative: { delta in
                        let target = max(0, min(viewModel.duration, viewModel.currentTime + delta))
                        viewModel.seek(to: target)
                    },
                    isFullscreen: true,
                    onToggleFullscreen: onExit
                )
                .opacity(showControls ? 1 : 0)
                .allowsHitTesting(showControls)
                .animation(.easeInOut(duration: 0.25), value: showControls)
            }

            // Click-through movement tracking over the whole surface (including the player layer).
            MouseMovedView { revealControls() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onExitCommand { onExit() }
        .onAppear { scheduleHide() }
        .onDisappear {
            hideTask?.cancel()
            NSCursor.unhide()
        }
        .onChange(of: viewModel.isPlaying) { _, playing in
            // Keep the controls up while paused; resume auto-hide once playing.
            if playing {
                scheduleHide()
            } else {
                hideTask?.cancel()
                showControls = true
                NSCursor.unhide()
            }
        }
    }

    private func revealControls() {
        showControls = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: Self.idleInterval)
            guard !Task.isCancelled, viewModel.isPlaying else { return }
            showControls = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

/// Reports pointer movement across its bounds via an always-active tracking area, while passing
/// clicks through (hitTest returns nil) so the overlaid transport controls remain interactive.
private struct MouseMovedView: NSViewRepresentable {
    let onMoved: () -> Void

    func makeNSView(context: Context) -> TrackingNSView {
        let view = TrackingNSView()
        view.onMoved = onMoved
        return view
    }

    func updateNSView(_ nsView: TrackingNSView, context: Context) {
        nsView.onMoved = onMoved
    }

    final class TrackingNSView: NSView {
        var onMoved: (() -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .activeAlways, .inVisibleRect],
                owner: self
            ))
        }

        override func mouseMoved(with event: NSEvent) { onMoved?() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Presents `FullscreenVideoView` in a borderless window covering the screen — nothing but the
/// video, no tab strip or toolbar — with the menu bar and Dock hidden. Driven by `isFullscreen`.
private struct FullscreenPresenter: NSViewRepresentable {
    var viewModel: VideoViewModel
    @Binding var isFullscreen: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isFullscreen {
            let screen = nsView.window?.screen ?? NSScreen.main
            guard let screen else { return }
            context.coordinator.controller.show(viewModel: viewModel, on: screen) {
                isFullscreen = false
            }
        } else {
            context.coordinator.controller.hide()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        let controller = FullscreenPlayerController()
    }
}

/// Borderless windows can't become key by default; allow it so keyboard (Escape) reaches us.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class FullscreenPlayerController {
    private var window: NSWindow?
    private var escMonitor: Any?
    private var savedPresentationOptions: NSApplication.PresentationOptions?

    func show(viewModel: VideoViewModel, on screen: NSScreen, onExit: @escaping () -> Void) {
        guard window == nil else { return }

        let hosting = NSHostingController(rootView: FullscreenVideoView(viewModel: viewModel, onExit: onExit))

        let win = KeyableWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.contentViewController = hosting
        win.setFrame(screen.frame, display: true)
        win.level = .mainMenu + 1
        win.isOpaque = true
        win.backgroundColor = .black
        win.acceptsMouseMovedEvents = true
        win.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]

        savedPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]

        // Arrow-key seeking is driven here rather than via SwiftUI keyboardShortcut: the
        // transport's zero-size arrow buttons don't receive arrow keys inside the borderless
        // hosting window. Escape exits.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak viewModel] event in
            switch event.keyCode {
            case 53: // Escape
                onExit()
                return nil
            case 123: // Left arrow — back 15s
                if let viewModel {
                    viewModel.seek(to: max(0, min(viewModel.duration, viewModel.currentTime - 15)))
                }
                return nil
            case 124: // Right arrow — forward 15s
                if let viewModel {
                    viewModel.seek(to: max(0, min(viewModel.duration, viewModel.currentTime + 15)))
                }
                return nil
            default:
                return event
            }
        }

        win.makeKeyAndOrderFront(nil)
        window = win
    }

    func hide() {
        guard window != nil else { return }
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
        if let savedPresentationOptions {
            NSApp.presentationOptions = savedPresentationOptions
            self.savedPresentationOptions = nil
        }
        window?.orderOut(nil)
        window = nil
    }
}

// MARK: - Row

struct VideoRowView: View {
    let date: Date
    let isPlaying: Bool
    let onTap: () -> Void
    let onTranscribe: () -> Void
    var viewModel: VideoViewModel

    @State private var showTagPopover = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)

            let tags = viewModel.metadata.tags(for: date)
            if !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
                .lineLimit(1)
            }

            Spacer()

            Text(date.timeString)
                .font(.caption)
                .foregroundStyle(.secondary)

            if isPlaying {
                Image(systemName: "video.fill")
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Manage Tags") {
                showTagPopover = true
            }
            .disabled(!viewModel.metadataLoaded)
            if #available(macOS 26.0, *) {
                Button("Transcribe to Bedit") {
                    onTranscribe()
                }
                .disabled(viewModel.isTranscribing)
            }
            Button("Export") {
                Task {
                    await viewModel.exportSelected()
                }
            }
            .disabled(viewModel.selectedDates.isEmpty)
        }
        .tagPopover(
            isPresented: $showTagPopover,
            date: date,
            selectedDates: viewModel.selectedDates,
            viewModel: viewModel
        )
    }
}

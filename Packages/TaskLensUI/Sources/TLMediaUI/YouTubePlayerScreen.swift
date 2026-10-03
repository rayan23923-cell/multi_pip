import SwiftUI
import TLCoreServices
import TLDesignSystem
import TLLocalization
import WebKit

/// The web view that hosts YouTube's player. Nothing is drawn over it.
public struct YouTubePlayerView: UIViewRepresentable {
    private let service: YouTubePlayerService

    public init(service: YouTubePlayerService) {
        self.service = service
    }

    public func makeUIView(context: Context) -> WKWebView {
        service.webView.accessibilityIdentifier = "youtube.player"
        return service.webView
    }

    public func updateUIView(_ view: WKWebView, context: Context) {}
}

/// "Play in TaskLens" for a YouTube link: YouTube's embedded player, with
/// Play, Pause and 10-second skips through the player API, and Open in YouTube.
/// No Picture in Picture button: TaskLens cannot put YouTube's player in it.
public struct YouTubePlayerScreen: View {
    private let video: YouTubeLink
    @State private var service = YouTubePlayerService()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    public init(video: YouTubeLink) {
        self.video = video
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    YouTubePlayerView(service: service)
                        // YouTube asks for at least 200 × 200 points; 16:9 at full width.
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(minHeight: 200)
                        .listRowInsets(EdgeInsets())
                    status
                    controls
                } footer: {
                    Text(L10nKey.videoNote)
                }

                Section {
                    LabeledContent {
                        Text(verbatim: video.videoID)
                            .textSelection(.enabled)
                            .environment(\.layoutDirection, .leftToRight)
                    } label: {
                        Text(L10nKey.analysisVideoID)
                    }
                    Button {
                        service.pauseForBackground()
                        openURL(video.watchURL)
                    } label: {
                        Label {
                            Text(L10nKey.actionOpenInYouTube)
                        } icon: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                    }
                    .accessibilityIdentifier("youtube.openInYouTube")
                }
            }
            .navigationTitle(Text(L10nKey.analysisYoutubeVideo))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(L10nKey.commonDone) }
                        .accessibilityIdentifier("youtube.done")
                }
            }
        }
        .task { service.load(video) }
        .onDisappear { service.unload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { service.pauseForBackground() }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: TLSpacing.xxs) {
            Text(Self.stateKey(service.state))
                .font(.subheadline.weight(.semibold))
            if service.duration > 0 {
                Text(verbatim: Self.time(service.currentTime) + " / " + Self.time(service.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("youtube.state")
        .accessibilityValue(Text(verbatim: service.state.name + (service.errorCode.map { ".\($0)" } ?? "")))
    }

    private var controls: some View {
        HStack(spacing: TLSpacing.l) {
            Button { service.seek(by: -10) } label: {
                Label { Text(L10nKey.videoBack) } icon: { Image(systemName: "gobackward.10") }
            }
            .accessibilityIdentifier("youtube.back")
            if service.state == .playing || service.state == .buffering {
                Button { service.pause() } label: {
                    Label { Text(L10nKey.videoPause) } icon: { Image(systemName: "pause.fill") }
                }
                .accessibilityIdentifier("youtube.pause")
            } else {
                Button { service.play() } label: {
                    Label { Text(L10nKey.videoPlay) } icon: { Image(systemName: "play.fill") }
                }
                .accessibilityIdentifier("youtube.play")
            }
            Button { service.seek(by: 10) } label: {
                Label { Text(L10nKey.videoForward) } icon: { Image(systemName: "goforward.10") }
            }
            .accessibilityIdentifier("youtube.forward")
        }
        .labelStyle(.iconOnly)
        .font(.title2)
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity)
        .disabled(!service.canControl)
    }

    static func stateKey(_ state: YouTubePlayerService.State) -> L10nKey {
        switch state {
        case .idle, .loading: .videoStateLoading
        case .ready: .videoStateReady
        case .playing: .videoStatePlaying
        case .paused: .videoStatePaused
        case .buffering: .videoStateBuffering
        case .ended: .videoStateEnded
        case .failed(.notLoaded): .videoErrorOffline
        case .failed(.embeddingNotAllowed): .videoErrorEmbedding
        case .failed(.notFound): .videoErrorNotFound
        case .failed: .videoErrorOther
        }
    }

    static func time(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

extension YouTubePlayerService {
    /// True once the player answered and has not failed.
    public var canControl: Bool {
        switch state {
        case .ready, .playing, .paused, .buffering, .ended: true
        case .idle, .loading, .failed: false
        }
    }
}

#if DEBUG
import AVKit
import SwiftUI
import TLCoreServices
import UIKit

/// Debug builds only: the YouTube → Picture in Picture feasibility lab.
///
/// 1. YouTube's embedded player (IFrame Player API) in TaskLens.
/// 2. Native media → AVPlayerLayer → AVPictureInPictureController.
/// 3. The YouTube app, which has its own Picture in Picture.
///
/// Every step is logged with what AVKit and the YouTube player reported, so
/// a run on a real iPhone can be copied and reviewed. Developer tool: its
/// text is not localized and it is not in Release builds.
public struct VideoPiPLabView: View {
    @State private var youtube = YouTubePlayerService(allowsSystemPictureInPicture: true)
    @State private var native = NativeVideoPiP()
    @State private var urlText = "https://youtu.be/M7lc1UVf-VE"
    @State private var source: NativeVideoPiP.Source = .generated
    @State private var labLog: [String] = []
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    private var parsed: YouTubeLink? { YouTubeLink.parse(urlText) }

    public var body: some View {
        List {
            youtubeSection
            nativeSection
            externalSection
            logSection
            checklistSection
        }
        .navigationTitle(Text(verbatim: "Video PiP Lab"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, phase in
            note("scene \(phase)")
            if phase == .background {
                note("background: YouTube state \(youtube.state.name), native PiP active \(native.isActive), native playing \(native.isPlaying)")
                youtube.pauseForBackground()
            }
        }
        .onDisappear { youtube.unload() }
    }

    // MARK: 1. YouTube

    private var youtubeSection: some View {
        Section {
            TextField(text: $urlText) { Text(verbatim: "YouTube URL") }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("lab.yt.url")
            Text(verbatim: parsed.map { "videoID \($0.videoID) · platform youtube · contentType video · kind \($0.kind.rawValue)" }
                ?? "Not a YouTube video link")
                .font(.caption.monospaced())
                .accessibilityIdentifier("lab.yt.parsed")
            Button {
                guard let parsed else { return }
                note("YouTube load \(parsed.videoID)")
                youtube.load(parsed)
            } label: { Text(verbatim: "Load Video") }
                .disabled(parsed == nil)
                .accessibilityIdentifier("lab.yt.load")
            if youtube.video != nil {
                YouTubePlayerView(service: youtube)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(minHeight: 200)
                    .listRowInsets(EdgeInsets())
            }
            Text(verbatim: "state \(youtube.state.name) · \(String(format: "%.1f", youtube.currentTime)) / \(String(format: "%.1f", youtube.duration)) s")
                .font(.caption.monospaced())
                .accessibilityIdentifier("lab.yt.state")
                .accessibilityValue(Text(verbatim: youtube.state.name))
            HStack {
                labControl("Play", id: "lab.yt.play") { youtube.play() }
                labControl("Pause", id: "lab.yt.pause") { youtube.pause() }
                labControl("+10 s", id: "lab.yt.forward") { youtube.seek(by: 10) }
                labControl("Stop", id: "lab.yt.stop") { youtube.stop() }
            }
            labControl("Try native PiP for this player", id: "lab.yt.pip") {
                note("YouTube → AVPictureInPictureController: NOT SUPPORTED. ContentSource accepts AVPlayerLayer, "
                     + "AVSampleBufferDisplayLayer or a video-call view; the YouTube player is a WKWebView. "
                     + "isPictureInPictureSupported = \(AVPictureInPictureController.isPictureInPictureSupported())")
            }
        } header: {
            Text(verbatim: "1 · YouTube IFrame Player in TaskLens")
        } footer: {
            Text(verbatim: "WebKit's own HTML5 Picture in Picture is allowed in this lab only. If YouTube's fullscreen player shows a PiP button, note it. TaskLens cannot start or observe that PiP, and pauses YouTube when it goes to the background (YouTube API policy III.I.9).")
        }
    }

    // MARK: 2. Native media

    private var nativeSection: some View {
        Section {
            Picker(selection: $source) {
                Text(verbatim: "Test video made on device (offline)").tag(NativeVideoPiP.Source.generated)
                Text(verbatim: "Apple HLS example (network)").tag(NativeVideoPiP.Source.appleSample)
            } label: { Text(verbatim: "Media") }
            labControl("Load Media", id: "lab.native.load") {
                note("native load \(source.rawValue)")
                Task { await native.load(source) }
            }
            PlayerLayerView(layer: native.playerLayer)
                .aspectRatio(16 / 9, contentMode: .fit)
                .listRowInsets(EdgeInsets())
            Text(verbatim: nativeStatus)
                .font(.caption.monospaced())
                .accessibilityIdentifier("lab.native.status")
                .accessibilityValue(Text(verbatim: nativeStatus))
            HStack {
                labControl("Play", id: "lab.native.play") { native.play() }
                labControl("Pause", id: "lab.native.pause") { native.pause() }
                labControl("+10 s", id: "lab.native.forward") { native.seek(by: 10) }
            }
            HStack {
                labControl("Start PiP", id: "lab.native.startPiP") { native.startPictureInPicture() }
                labControl("Stop PiP", id: "lab.native.stopPiP") { native.stopPictureInPicture() }
            }
        } header: {
            Text(verbatim: "2 · Native media → AVPictureInPictureController")
        } footer: {
            Text(verbatim: "AVPlayer → AVPlayerLayer → AVPictureInPictureController(contentSource: playerLayer). Leaving TaskLens while it plays starts PiP automatically.")
        }
    }

    private var nativeStatus: String {
        "supported=\(native.isSupported) possible=\(native.isPossible) active=\(native.isActive) "
            + "playing=\(native.isPlaying) loaded=\(native.isLoaded) restores=\(native.restoreCount) "
            + "t=\(String(format: "%.1f", native.currentTime))"
    }

    // MARK: 3. External

    private var externalSection: some View {
        Section {
            labControl("Open in YouTube", id: "lab.external.open") {
                guard let parsed else { return }
                youtube.pauseForBackground()
                note("open \(parsed.watchURL.absoluteString)")
                openURL(parsed.watchURL) { accepted in note("openURL accepted \(accepted)") }
            }
            .disabled(parsed == nil)
        } header: {
            Text(verbatim: "3 · YouTube app")
        } footer: {
            Text(verbatim: "Opens the YouTube app (universal link) or the web page. Any PiP there belongs to YouTube and iOS; TaskLens does not control it.")
        }
    }

    // MARK: Log

    private var logSection: some View {
        Section {
            labControl("Copy Log", id: "lab.log.copy") { UIPasteboard.general.string = fullLog.joined(separator: "\n") }
            ForEach(Array(fullLog.suffix(60).enumerated()), id: \.offset) { _, line in
                Text(verbatim: line).font(.caption2.monospaced())
            }
        } header: {
            Text(verbatim: "Log")
        }
    }

    private var fullLog: [String] {
        let device = UIDevice.current
        let header = "device \(device.model) iOS \(device.systemVersion) · origin \(YouTubePlayerService.appOrigin.absoluteString)"
        let youtubeLines = youtube.log.map { "yt \($0.date.formatted(.dateTime.hour().minute().second())) \($0.text)" }
        return [header] + labLog + youtubeLines + native.log.map { "pip \($0)" }
    }

    private var checklistSection: some View {
        Section {
            ForEach(Self.checklist, id: \.self) { step in
                Text(verbatim: step).font(.footnote)
            }
        } header: {
            Text(verbatim: "Real iPhone checklist")
        }
    }

    static let checklist = [
        "Native: Load (offline video) → Play → Start PiP → window appears",
        "Native: Home → PiP stays over the Home Screen and another app",
        "Native: Tap PiP's restore button → TaskLens returns, restores +1",
        "Native: Stop PiP → video continues inline at the same time",
        "Native: Lock the screen while in PiP, unlock, check state",
        "Native: Call or Siri during PiP (interruption), check state",
        "Native: Apple HLS on Wi-Fi, mobile data, then offline",
        "YouTube: Load → Play → Pause → +10 s → Stop on Wi-Fi and mobile data",
        "YouTube: Offline → Load shows error.notLoaded",
        "YouTube: Fullscreen in YouTube's player: is there a PiP button?",
        "YouTube: Home while playing → log shows the pause",
        "YouTube app: Open in YouTube → play → Home → YouTube's PiP",
        "Copy Log and send it back",
    ]

    private func note(_ text: String) {
        labLog.append("lab \(Date().formatted(.dateTime.hour().minute().second())) \(text)")
    }

    /// Lab controls are English, like the rest of this Debug-only screen.
    private func labControl(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(verbatim: title) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(id)
    }
}

/// Hosts the lab's AVPlayerLayer.
private struct PlayerLayerView: UIViewRepresentable {
    let layer: AVPlayerLayer

    func makeUIView(context: Context) -> LayerHost {
        let view = LayerHost()
        view.backgroundColor = .black
        view.hosted = layer
        view.layer.addSublayer(layer)
        return view
    }

    func updateUIView(_ view: LayerHost, context: Context) {}

    final class LayerHost: UIView {
        var hosted: CALayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            hosted?.frame = bounds
        }
    }
}
#endif

import Foundation
import Observation
import TLCoreServices
import WebKit

/// YouTube's own embedded player (the documented IFrame Player API) in a web
/// view, driven through its JavaScript API.
///
/// What it does not do, by design and by YouTube's API policies: no stream
/// URLs, no downloads, no changes to the player, nothing drawn over it, and
/// no playback while the player is not on screen (it pauses when TaskLens
/// goes to the background). The video plays only in YouTube's player, so it
/// cannot be a source for TaskLens' own Picture in Picture: AVKit takes an
/// AVPlayerLayer or an AVSampleBufferDisplayLayer, and a web view is neither.
@MainActor
@Observable
public final class YouTubePlayerService {
    public enum State: Equatable, Sendable {
        case idle
        case loading
        case ready
        case playing
        case paused
        case buffering
        case ended
        case failed(Failure)

        /// Stable name for logs and UI tests.
        public var name: String {
            switch self {
            case .idle: "idle"
            case .loading: "loading"
            case .ready: "ready"
            case .playing: "playing"
            case .paused: "paused"
            case .buffering: "buffering"
            case .ended: "ended"
            case .failed(let failure): "error.\(failure.rawValue)"
            }
        }
    }

    /// Why the video cannot play. Codes from the IFrame API's onError.
    public enum Failure: String, Equatable, Sendable {
        /// 2: the video ID was rejected.
        case invalidVideo
        /// 5: the HTML5 player failed.
        case playerError
        /// 100: removed or private.
        case notFound
        /// 101, 150: the owner does not allow embedding.
        case embeddingNotAllowed
        /// 153: the request did not identify the app (HTTP Referer).
        case missingIdentity
        /// The player API did not load: usually no internet connection.
        case notLoaded
        case unknown

        init(code: Int) {
            switch code {
            case 2: self = .invalidVideo
            case 5: self = .playerError
            case 100: self = .notFound
            case 101, 150: self = .embeddingNotAllowed
            case 153: self = .missingIdentity
            default: self = .unknown
            }
        }
    }

    public struct LogEntry: Identifiable, Sendable {
        public let id = UUID()
        public let date: Date
        public let text: String
    }

    public private(set) var state: State = .idle
    public private(set) var video: YouTubeLink?
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var log: [LogEntry] = []

    public let webView: WKWebView
    /// Seconds to wait for the player API before reporting `notLoaded`.
    @ObservationIgnored public var loadTimeout: Duration = .seconds(20)
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private let bridge = Bridge()

    /// `allowsSystemPictureInPicture`: WebKit's own Picture in Picture for HTML5
    /// video. Off in the app; the Video PiP Lab turns it on to test it.
    public init(allowsSystemPictureInPicture: Bool = false) {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        // Play starts only from the user's tap on Play, with the player on screen.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = allowsSystemPictureInPicture
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(bridge, name: Bridge.name)
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        bridge.onMessage = { [weak self] body in self?.receive(body) }
    }

    /// The app's identity for YouTube: `https://<bundle identifier>`, as YouTube
    /// asks native apps to send in the HTTP Referer (via the base URL).
    public static var appOrigin: URL {
        let identifier = (Bundle.main.bundleIdentifier ?? "com.example.tasklens").lowercased()
        return URL(string: "https://\(identifier)")!
    }

    public func load(_ video: YouTubeLink) {
        self.video = video
        currentTime = 0
        duration = 0
        set(.loading)
        record("load \(video.videoID) origin \(Self.appOrigin.absoluteString)")
        webView.loadHTMLString(Self.page(for: video, origin: Self.appOrigin), baseURL: Self.appOrigin)
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self, loadTimeout] in
            try? await Task.sleep(for: loadTimeout)
            guard let self, !Task.isCancelled, self.state == .loading else { return }
            self.set(.failed(.notLoaded))
        }
    }

    public func play() { call("player.playVideo()") }
    public func pause() { call("player.pauseVideo()") }

    public func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        call("player.seekTo(\(target), true)")
        currentTime = target
    }

    public func seek(by seconds: Double) { seek(to: currentTime + seconds) }

    public func stop() {
        call("player.stopVideo()")
        currentTime = 0
    }

    /// Ends the player and frees the page.
    public func unload() {
        timeoutTask?.cancel()
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        video = nil
        set(.idle)
    }

    /// YouTube's policies do not allow playback from a player the user cannot
    /// see, so playback pauses when TaskLens leaves the screen.
    public func pauseForBackground() {
        guard state == .playing || state == .buffering else { return }
        record("background: pausing (YouTube API policy III.I.9)")
        pause()
    }

    // MARK: Bridge

    private func call(_ script: String) {
        guard video != nil, state != .loading, !isFailed else {
            record("ignored \(script) in state \(state.name)")
            return
        }
        record("call \(script)")
        webView.evaluateJavaScript("if (window.player) { \(script) }", completionHandler: nil)
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func receive(_ body: Any) {
        guard let message = body as? [String: Any], let event = message["event"] as? String else { return }
        if let time = message["time"] as? Double { currentTime = time }
        if let total = message["duration"] as? Double, total > 0 { duration = total }
        switch event {
        case "ready":
            timeoutTask?.cancel()
            set(.ready)
        case "state":
            let code = message["state"] as? Int ?? -1
            switch code {
            case 0: set(.ended)
            case 1: set(.playing)
            case 2: set(.paused)
            case 3: set(.buffering)
            case 5: set(.ready)
            default: break
            }
        case "error":
            timeoutTask?.cancel()
            let code = message["code"] as? Int ?? -1
            record("error code \(code)")
            set(.failed(Failure(code: code)))
        case "time":
            break
        case "apiFailed":
            timeoutTask?.cancel()
            set(.failed(.notLoaded))
        default:
            break
        }
    }

    private func set(_ new: State) {
        guard state != new else { return }
        state = new
        record("state \(new.name) at \(String(format: "%.1f", currentTime))s")
    }

    func record(_ text: String) {
        log.append(LogEntry(date: Date(), text: text))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    /// The host page: the IFrame API script from youtube.com and a player
    /// made with documented parameters only.
    static func page(for video: YouTubeLink, origin: URL) -> String {
        let start = video.startSeconds.map { ", start: \($0)" } ?? ""
        return """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#player{position:absolute;inset:0;width:100%;height:100%}</style>
        </head><body>
        <div id="player"></div>
        <script>
        function send(message) { window.webkit.messageHandlers.\(Bridge.name).postMessage(message); }
        var player, ticker;
        function onYouTubeIframeAPIReady() {
          player = new YT.Player('player', {
            width: '100%', height: '100%', videoId: '\(video.videoID)',
            playerVars: { playsinline: 1, rel: 0, origin: '\(origin.absoluteString)'\(start) },
            events: {
              onReady: function () { send({ event: 'ready', duration: player.getDuration() }); },
              onStateChange: function (e) {
                send({ event: 'state', state: e.data, time: player.getCurrentTime(), duration: player.getDuration() });
                clearInterval(ticker);
                if (e.data === 1) {
                  ticker = setInterval(function () { send({ event: 'time', time: player.getCurrentTime() }); }, 1000);
                }
              },
              onError: function (e) { send({ event: 'error', code: e.data }); }
            }
          });
        }
        </script>
        <script src="https://www.youtube.com/iframe_api" onerror="send({ event: 'apiFailed' })"></script>
        </body></html>
        """
    }

    /// Script messages without a retain cycle through the content controller.
    private final class Bridge: NSObject, WKScriptMessageHandler {
        static let name = "tasklensYouTube"
        var onMessage: (@MainActor (Any) -> Void)?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body
            MainActor.assumeIsolated { onMessage?(body) }
        }
    }
}

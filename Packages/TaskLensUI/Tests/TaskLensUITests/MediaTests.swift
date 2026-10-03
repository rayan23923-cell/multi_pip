import Foundation
import Testing
import TLActionsUI
import TLCoreServices
import TLDomain
import TLLocalization
@testable import TLMediaUI

@Suite("YouTube in the action UI")
@MainActor
struct YouTubeActionUITests {
    private let url = URL(string: "https://youtu.be/dQw4w9WgXcQ?t=30")!

    private func action(_ type: ActionType) throws -> Action {
        let analysis = ActionEngine.analyze(.url(url), context: ActionContext(source: .manualEntry, preferredLanguage: "en"))
        return try #require(analysis.actions.first { $0.type == type })
    }

    @Test func playOpensYouTubesPlayerInTheApp() throws {
        let plan = ActionPlan.make(for: try action(.playVideo), content: .url(url))
        guard case .playVideo(let video) = plan else {
            Issue.record("expected playVideo, got \(plan)")
            return
        }
        #expect(video.videoID == "dQw4w9WgXcQ")
        #expect(video.startSeconds == 30)
    }

    @Test func shareSheetPointsToTheApp() throws {
        #expect(ActionPlan.make(for: try action(.playVideo), content: .url(url), capabilities: .shareExtension) == .openApp)
    }

    @Test func openInYouTubeOpensTheWatchPage() throws {
        let open = try action(.openURL)
        #expect(L10nKey.action(open) == .actionOpenInYouTube)
        #expect(ActionPlan.make(for: open, content: .url(url)) == .open(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=30s")!))
    }

    @Test func playWithoutAVideoIsUnavailable() {
        #expect(ActionPlan.make(for: Action(type: .playVideo), content: nil) == .unavailable)
    }
}

@Suite("YouTube player")
@MainActor
struct YouTubePlayerServiceTests {
    @Test func pageUsesOnlyTheDocumentedPlayer() throws {
        let video = try #require(YouTubeLink(videoID: "dQw4w9WgXcQ", startSeconds: 12))
        let page = YouTubePlayerService.page(for: video, origin: URL(string: "https://com.example.tasklens")!)
        #expect(page.contains("https://www.youtube.com/iframe_api"))
        #expect(page.contains("videoId: 'dQw4w9WgXcQ'"))
        #expect(page.contains("playsinline: 1"))
        #expect(page.contains("origin: 'https://com.example.tasklens'"))
        #expect(page.contains("start: 12"))
        // No autoplay: playback starts only from the user's Play.
        #expect(!page.contains("autoplay"))
        #expect(!page.contains("playVideo"))
    }

    @Test func appOriginIsTheBundleIdentifierOverHTTPS() {
        #expect(YouTubePlayerService.appOrigin.scheme == "https")
        #expect(YouTubePlayerService.appOrigin.host?.isEmpty == false)
    }

    @Test func commandsBeforeTheplayerIsReadyAreIgnored() {
        let service = YouTubePlayerService()
        service.play()
        #expect(service.state == .idle)
        #expect(service.log.last?.text.hasPrefix("ignored") == true)
    }

    @Test func failuresMapToMessages() {
        #expect(YouTubePlayerScreen.stateKey(.failed(.notLoaded)) == .videoErrorOffline)
        #expect(YouTubePlayerScreen.stateKey(.failed(.embeddingNotAllowed)) == .videoErrorEmbedding)
        #expect(YouTubePlayerScreen.stateKey(.failed(.notFound)) == .videoErrorNotFound)
        #expect(YouTubePlayerScreen.stateKey(.failed(.missingIdentity)) == .videoErrorOther)
        #expect(YouTubePlayerScreen.stateKey(.playing) == .videoStatePlaying)
        #expect(YouTubePlayerScreen.time(75.9) == "1:15")
    }
}

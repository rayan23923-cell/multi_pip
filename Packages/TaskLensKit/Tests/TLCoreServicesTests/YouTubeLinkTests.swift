import Foundation
import Testing
import TLCoreServices
import TLDomain
import TLFoundation

private func link(_ text: String) -> YouTubeLink? {
    URL(string: text).flatMap { YouTubeLink.parse($0) }
}

@Suite("YouTube link parser")
struct YouTubeLinkParserTests {
    @Test(arguments: [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtube.com/watch?v=dQw4w9WgXcQ",
        "https://m.youtube.com/watch?v=dQw4w9WgXcQ",
        "http://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL123&index=2",
        "https://www.youtube.com/watch?feature=share&v=dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ?si=abcDEF123",
        "https://www.youtube.com/embed/dQw4w9WgXcQ",
        "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ",
        "HTTPS://WWW.YOUTUBE.COM/watch?v=dQw4w9WgXcQ",
    ])
    func videoLinks(_ text: String) throws {
        let video = try #require(link(text))
        #expect(video.videoID == "dQw4w9WgXcQ")
        #expect(video.kind == .video)
    }

    @Test func shorts() throws {
        let video = try #require(link("https://youtube.com/shorts/abcdefghijk"))
        #expect(video.videoID == "abcdefghijk")
        #expect(video.kind == .short)
        #expect(video.watchURL.absoluteString == "https://www.youtube.com/shorts/abcdefghijk")
        #expect(link("https://www.youtube.com/shorts/abcdefghijk?feature=share")?.kind == .short)
    }

    @Test func live() {
        #expect(link("https://www.youtube.com/live/A-b_c1234Z9")?.kind == .live)
    }

    @Test func idsKeepDashAndUnderscore() {
        #expect(link("https://youtu.be/-_aZ09-_aZ0")?.videoID == "-_aZ09-_aZ0")
    }

    @Test(arguments: [
        "https://www.youtube.com/",
        "https://www.youtube.com/watch",
        "https://www.youtube.com/watch?v=",
        "https://www.youtube.com/watch?v=short",
        "https://www.youtube.com/watch?v=dQw4w9WgXcQQ",  // 12 characters
        "https://www.youtube.com/watch?v=dQw4w9WgX%20Q",
        "https://www.youtube.com/@channel",
        "https://www.youtube.com/playlist?list=PL123",
        "https://www.youtube.com/results?search_query=swift",
        "https://youtu.be/",
        "https://notyoutube.com/watch?v=dQw4w9WgXcQ",
        "https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ",
        "https://vimeo.com/123456",
        "ftp://youtu.be/dQw4w9WgXcQ",
        "youtube://dQw4w9WgXcQ",
    ])
    func notVideos(_ text: String) {
        #expect(link(text) == nil)
    }

    @Test func startTime() {
        #expect(link("https://youtu.be/dQw4w9WgXcQ?t=90")?.startSeconds == 90)
        #expect(link("https://youtu.be/dQw4w9WgXcQ?t=90s")?.startSeconds == 90)
        #expect(link("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1m30s")?.startSeconds == 90)
        #expect(link("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1h2m3s")?.startSeconds == 3723)
        #expect(link("https://www.youtube.com/embed/dQw4w9WgXcQ?start=42")?.startSeconds == 42)
        #expect(link("https://youtu.be/dQw4w9WgXcQ?t=abc")?.startSeconds == nil)
        #expect(link("https://youtu.be/dQw4w9WgXcQ?t=0")?.startSeconds == nil)
    }

    @Test func canonicalWatchURL() throws {
        let video = try #require(link("https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=90"))
        #expect(video.watchURL.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=90s")
        #expect(link("https://youtu.be/dQw4w9WgXcQ")?.watchURL.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    @Test func fromText() {
        #expect(YouTubeLink.parse("  youtu.be/dQw4w9WgXcQ \n")?.videoID == "dQw4w9WgXcQ")
        #expect(YouTubeLink.parse("watch https://youtu.be/dQw4w9WgXcQ") == nil)
        #expect(YouTubeLink.parse("") == nil)
    }
}

@Suite("YouTube links in the engines")
struct YouTubeEngineTests {
    private let context = ActionContext(source: .manualEntry, preferredLanguage: "en")

    @Test func detectorAddsPlatformMetadataOffline() throws {
        // No network: the ID is read from the URL.
        let analysis = ActionEngine.analyze(.url(URL(string: "https://youtu.be/dQw4w9WgXcQ")!), context: context)
        #expect(analysis.category == .url)
        let entity = try #require(analysis.primaryEntity)
        #expect(entity.metadata[DetectionKey.platform]?.stringValue == "youtube")
        #expect(entity.metadata[DetectionKey.contentType]?.stringValue == "video")
        #expect(entity.metadata[DetectionKey.videoID]?.stringValue == "dQw4w9WgXcQ")
        #expect(analysis.youTubeLink?.videoID == "dQw4w9WgXcQ")
    }

    @Test func typedLinkIsAlsoDetected() {
        let analysis = ActionEngine.analyze(.text("https://www.youtube.com/shorts/abcdefghijk"), context: context)
        #expect(analysis.youTubeLink?.kind == .short)
    }

    @Test func otherLinksHaveNoPlatform() throws {
        let analysis = ActionEngine.analyze(.url(URL(string: "https://apple.com")!), context: context)
        #expect(analysis.youTubeLink == nil)
        #expect(try #require(analysis.primaryEntity).metadata[DetectionKey.platform] == nil)
        #expect(!analysis.actions.contains { $0.type == .playVideo })
    }

    @Test func actionsForAYouTubeLink() throws {
        let analysis = ActionEngine.analyze(.url(URL(string: "https://m.youtube.com/watch?v=dQw4w9WgXcQ")!), context: context)
        let suggestions = analysis.suggestions
        #expect(suggestions.primary.map(\.type) == [.openURL, .playVideo, .saveToSession])
        let open = try #require(suggestions.primary.first)
        #expect(open.titleKey == Action.openInYouTubeTitleKey)
        #expect(open.valueText == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        let play = suggestions.primary[1]
        #expect(play.parameters[Action.ParameterKey.videoID]?.stringValue == "dQw4w9WgXcQ")
        // Secondary: Search, Share, Copy, Create Note follow. No Picture in Picture action exists.
        let all = suggestions.all.map(\.type)
        #expect(Set(all).isSuperset(of: [.copy, .share, .createNote, .search]))
        #expect(!all.contains { $0.rawValue.lowercased().contains("pip") || $0.rawValue.lowercased().contains("picture") })
    }

    @Test func fromTheShareSheetPlayNeedsTheApp() {
        let shared = ActionContext(source: .shareExtension, preferredLanguage: "en")
        let analysis = ActionEngine.analyze(.url(URL(string: "https://youtu.be/dQw4w9WgXcQ")!), context: shared)
        #expect(analysis.suggestions.primary.first?.type == .saveToSession)
        #expect(analysis.actions.contains { $0.type == .playVideo })
    }

    @Test func savedToASessionKeepsTheVideoAndIsFoundBySearch() async throws {
        let env = TestEnvironment(detector: ContextEngine())
        let workspace = try await env.workspaces.create(name: "Videos")
        let session = try await env.sessions.start(in: workspace.id)
        let url = URL(string: "https://youtu.be/dQw4w9WgXcQ")!
        let saved = try await env.capture.capture(.url(url), source: .shareExtension, into: session.id)

        // Restoring the session gives back the same item with its video metadata.
        let restored = try #require(try await env.capture.items(in: session.id).first)
        #expect(restored.id == saved.id)
        #expect(restored.sessionID == session.id)
        #expect(restored.createdAt == env.clock.now())
        let entity = try #require(restored.entities.first { $0.type == .url })
        #expect(entity.youTubeLink?.videoID == "dQw4w9WgXcQ")
        #expect(entity.metadata[DetectionKey.platform]?.stringValue == "youtube")
        #expect(entity.metadata[DetectionKey.contentType]?.stringValue == "video")

        let search = SearchService(
            workspaces: env.repositories.workspaces,
            sessions: env.repositories.sessions,
            contextItems: env.repositories.contextItems
        )
        #expect(try await search.search("dQw4w9WgXcQ").items.map(\.id) == [saved.id])
        #expect(try await search.search("youtu").items.map(\.id) == [saved.id])
    }
}

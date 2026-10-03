import Foundation

/// A YouTube video found in a link, read from the URL alone: no network.
///
/// Recognized forms:
///
///     https://www.youtube.com/watch?v=VIDEO_ID
///     https://m.youtube.com/watch?v=VIDEO_ID
///     https://youtu.be/VIDEO_ID
///     https://youtube.com/shorts/VIDEO_ID
///     https://www.youtube.com/live/VIDEO_ID
///     https://www.youtube.com/embed/VIDEO_ID (also youtube-nocookie.com)
///
/// A `t=` or `start=` time (`90`, `90s`, `1m30s`, `1h2m3s`) is kept as the start.
public struct YouTubeLink: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable {
        case video
        case short
        case live
    }

    public let videoID: String
    public let kind: Kind
    /// Where playback should start, from the link's time parameter.
    public let startSeconds: Int?

    public static let platform = "youtube"
    public static let contentType = "video"

    public init?(videoID: String, kind: Kind = .video, startSeconds: Int? = nil) {
        guard Self.isValidVideoID(videoID) else { return nil }
        self.videoID = videoID
        self.kind = kind
        self.startSeconds = startSeconds.flatMap { $0 > 0 ? $0 : nil }
    }

    /// The canonical watch page. Opens the YouTube app when it is installed
    /// (a universal link); otherwise the web page.
    public var watchURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        if kind == .short {
            components.path = "/shorts/\(videoID)"
        } else {
            components.path = "/watch"
            components.queryItems = [URLQueryItem(name: "v", value: videoID)]
            if let startSeconds {
                components.queryItems?.append(URLQueryItem(name: "t", value: "\(startSeconds)s"))
            }
        }
        return components.url!
    }

    // MARK: Parsing

    static let watchHosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"]
    static let embedHosts: Set<String> = ["youtube-nocookie.com", "www.youtube-nocookie.com"]
    static let shortHosts: Set<String> = ["youtu.be", "www.youtu.be"]

    /// Nil unless the URL is a YouTube video link with a well-formed video ID.
    public static func parse(_ url: URL) -> YouTubeLink? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        let query = components.queryItems ?? []
        func item(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let start = (item("t") ?? item("start")).flatMap(seconds(from:))

        if shortHosts.contains(host) {
            guard let id = path.first else { return nil }
            return YouTubeLink(videoID: id, startSeconds: start)
        }
        guard watchHosts.contains(host) || embedHosts.contains(host) else { return nil }
        switch path.first {
        case "watch" where path.count == 1:
            return item("v").flatMap { YouTubeLink(videoID: $0, startSeconds: start) }
        case "shorts" where path.count >= 2:
            return YouTubeLink(videoID: path[1], kind: .short, startSeconds: start)
        case "live" where path.count >= 2:
            return YouTubeLink(videoID: path[1], kind: .live, startSeconds: start)
        case "embed" where path.count >= 2, "v" where path.count >= 2:
            return YouTubeLink(videoID: path[1], startSeconds: start)
        default:
            return nil
        }
    }

    /// Text that is a single YouTube link.
    public static func parse(_ text: String) -> YouTubeLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace) else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        return URL(string: withScheme).flatMap { parse($0) }
    }

    /// Video IDs are 11 characters from `A–Z a–z 0–9 - _`.
    public static func isValidVideoID(_ id: String) -> Bool {
        id.count == 11 && id.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "-", "_": true
            default: false
            }
        }
    }

    /// "90", "90s", "1m30s", "1h2m3s" → seconds. Nil for anything else.
    static func seconds(from text: String) -> Int? {
        if let plain = Int(text) { return plain >= 0 ? plain : nil }
        var total = 0, number = "", sawUnit = false
        for character in text.lowercased() {
            if character.isASCII, character.isNumber {
                number.append(character)
                continue
            }
            guard let value = Int(number) else { return nil }
            switch character {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default: return nil
            }
            number = ""
            sawUnit = true
        }
        return sawUnit && number.isEmpty ? total : nil
    }
}

extension YouTubeLink: Identifiable {
    public var id: String { videoID }
}

import Foundation
import os
import TLCoreServices
import UIKit
import WebKit

/// Turns an imported .pptx into one image per slide, on the device and offline.
///
/// WebKit's built-in PowerPoint support (OfficeImport) lays the deck out as one
/// `div.slide` per slide; each is snapshotted into `slide-001.png`,
/// `slide-002.png`... in presentation order. The file is untrusted:
/// - it must pass the import check (A9.1) and `PowerPointDeck.read` first;
/// - the web view has no stored data, no page JavaScript, no new windows, no
///   media, and only the file itself may load: web requests are blocked by a
///   content rule list and any other navigation is cancelled;
/// - one web view at a time, removed when the render ends.
///
/// The paragraph direction fix from A8 (`p { unicode-bidi: plaintext }`) is
/// applied so Arabic sentences keep their right-to-left order.
///
/// Output is all or nothing: images are written to a temporary folder that
/// becomes `destination` only when every visible slide rendered. On any
/// failure, timeout or cancellation the folder is removed. Hidden slides are
/// not rendered. Animations, media, links and speaker notes are not rendered.
@MainActor
public final class PowerPointRenderer {
    public enum ImageFormat: Sendable, Equatable {
        case png
        case jpeg(quality: Double)

        var fileExtension: String {
            switch self {
            case .png: "png"
            case .jpeg: "jpg"
            }
        }
    }

    public struct Options: Sendable {
        public var format: ImageFormat
        /// Pixels on the slide's longer side.
        public var longestSidePixels: Int
        /// For the whole render, from opening the file to the last image.
        public var timeout: Duration
        /// Loads a missing file instead of the deck, to exercise WebKit's own failure path.
        @_spi(Testing) public var simulatesWebViewFailure = false

        public init(format: ImageFormat = .png, longestSidePixels: Int = 1920, timeout: Duration = .seconds(180)) {
            self.format = format
            self.longestSidePixels = longestSidePixels
            self.timeout = timeout
        }
    }

    public struct Output: Sendable {
        public struct Slide: Sendable, Equatable {
            /// 1-based, matches the file name.
            public var index: Int
            /// The slide this image shows, from `deck.slides`.
            public var source: PowerPointDeck.Slide
            public var fileURL: URL
            public var pixelWidth: Int
            public var pixelHeight: Int
            public var byteCount: Int
        }

        /// `destination`, holding exactly the files in `slides`.
        public var directory: URL
        public var slides: [Slide]
        public var deck: PowerPointDeck
        public var diagnostics: Diagnostics
    }

    /// Measurements and checks from one render, for tests and logs.
    public struct Diagnostics: Sendable {
        public var loadSeconds: Double = 0
        public var snapshotSeconds: Double = 0
        public var totalSeconds: Double = 0
        public var webKitSlideCount = 0
        /// Resources the page loaded from anything but the file itself.
        public var externalRequestCount = 0
        public var blockedNavigationCount = 0
        public var brokenImageCount = 0
        /// The computed `unicode-bidi` of slide paragraphs is `plaintext`.
        public var directionFixApplied = false
        public var totalBytes = 0
        /// Snapshots taken again because WebKit hadn't finished painting the slide.
        public var snapshotRetries = 0
        /// WebKit's slide size in CSS pixels.
        public var webKitSlideSize: CGSize = .zero
    }

    /// Web views alive right now, and the most at once. Renders are serialized, so both stay at most 1.
    public private(set) static var liveWebViewCount = 0
    public private(set) static var peakWebViewCount = 0
    /// What went wrong in the last failed render (WebKit's error, or the
    /// geometry of a slide that didn't fit), for logs. Never holds file content.
    public private(set) static var lastFailureDetail: String?

    public init() {}

    /// Renders `fileURL` into a new folder at `destination`, which must not exist yet.
    /// `scene` hosts the hidden web view; nil uses the app's active scene.
    public func render(_ fileURL: URL, to destination: URL, options: Options = Options(),
                       in scene: UIWindowScene? = nil) async throws -> Output {
        await Self.gate.acquire()
        defer { Self.gate.release() }
        Self.lastFailureDetail = nil
        Self.lastUnpaintedImage = nil

        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(by: options.timeout)
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("PowerPointRender-\(UUID().uuidString)", isDirectory: true)
        let images = work.appendingPathComponent("slides", isDirectory: true)
        var session: WebSession?
        defer { session?.close() }

        do {
            try Task.checkCancellation()
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw PowerPointRenderError.renderingFailed(.writeFailed)
            }
            do {
                try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            } catch { throw PowerPointRenderError.renderingFailed(.writeFailed) }

            let deck = try await Task.detached(priority: .userInitiated) { try PowerPointDeck.read(contentsOf: fileURL) }.value
            guard !deck.visibleSlides.isEmpty else { throw PowerPointRenderError.renderingFailed(.noVisibleSlides) }
            let source = try Self.pptxCopy(of: fileURL, in: work)

            guard let scene = scene ?? Self.activeScene() else { throw PowerPointRenderError.webViewFailed }
            let rules = try await Self.offlineRules()
            let web = WebSession(deck: deck, scene: scene, rules: rules, deadline: deadline)
            session = web
            var diagnostics = Diagnostics()

            let loadURL = options.simulatesWebViewFailure ? work.appendingPathComponent("missing.pptx") : source
            try await web.load(loadURL)
            let layout = try await web.waitForSlides()
            diagnostics.loadSeconds = Self.seconds(clock.now - started)
            diagnostics.webKitSlideCount = layout.rects.count
            diagnostics.webKitSlideSize = layout.slideSize
            diagnostics.brokenImageCount = layout.brokenImages
            diagnostics.directionFixApplied = layout.directionFixApplied

            // WebKit may or may not lay out hidden slides; either way only visible ones are kept.
            let pairs: [(webIndex: Int, slide: PowerPointDeck.Slide)]
            if layout.rects.count == deck.slides.count {
                pairs = deck.slides.enumerated().filter { !$0.element.isHidden }.map { ($0.offset, $0.element) }
            } else if layout.rects.count == deck.visibleSlides.count {
                pairs = deck.visibleSlides.enumerated().map { ($0.offset, $0.element) }
            } else {
                throw PowerPointRenderError.renderingFailed(
                    .slideCountMismatch(expected: deck.visibleSlides.count, rendered: layout.rects.count))
            }
            let webAspect = layout.slideSize.width / max(layout.slideSize.height, 1)
            guard abs(webAspect / deck.aspectRatio - 1) < 0.02 else { throw PowerPointRenderError.renderingFailed(.slideSizeMismatch) }

            let snapshotStarted = clock.now
            var slides: [Output.Slide] = []
            for (number, pair) in pairs.enumerated() {
                let index = number + 1
                let shot = try await web.snapshot(layout.rects[pair.webIndex], webIndex: pair.webIndex, slide: index, deckAspect: deck.aspectRatio,
                                                  longestSidePixels: options.longestSidePixels, format: options.format)
                diagnostics.snapshotRetries += shot.retries
                let name = String(format: "slide-%03d.%@", index, options.format.fileExtension)
                do {
                    try shot.data.write(to: images.appendingPathComponent(name), options: .atomic)
                } catch { throw PowerPointRenderError.renderingFailed(.writeFailed) }
                slides.append(Output.Slide(index: index, source: pair.slide, fileURL: destination.appendingPathComponent(name),
                                           pixelWidth: shot.width, pixelHeight: shot.height, byteCount: shot.data.count))
            }
            diagnostics.snapshotSeconds = Self.seconds(clock.now - snapshotStarted)
            diagnostics.externalRequestCount = try await web.externalRequestCount()
            diagnostics.blockedNavigationCount = web.blockedNavigations
            diagnostics.totalBytes = slides.reduce(0) { $0 + $1.byteCount }
            web.close()
            session = nil

            try Task.checkCancellation()
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: images, to: destination)
            } catch { throw PowerPointRenderError.renderingFailed(.writeFailed) }
            try? FileManager.default.removeItem(at: work)
            diagnostics.totalSeconds = Self.seconds(clock.now - started)
            return Output(directory: destination, slides: slides, deck: deck, diagnostics: diagnostics)
        } catch {
            try? FileManager.default.removeItem(at: work)
            if error is CancellationError { throw PowerPointRenderError.cancelled }
            if let error = error as? PowerPointRenderError { throw error }
            throw PowerPointRenderError.webViewFailed
        }
    }

    // MARK: Setup

    /// The deck as `deck.pptx` in the work folder: WebKit picks its PowerPoint
    /// importer from the extension. A hard link costs nothing; a copy is the fallback.
    private static func pptxCopy(of fileURL: URL, in work: URL) throws -> URL {
        let copy = work.appendingPathComponent("deck.pptx")
        do {
            try FileManager.default.linkItem(at: fileURL, to: copy)
        } catch {
            do { try FileManager.default.copyItem(at: fileURL, to: copy) } catch { throw PowerPointRenderError.invalidPresentation }
        }
        return copy
    }

    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private static var compiledRules: WKContentRuleList?

    /// Blocks every web request; the deck may only use what is inside the file.
    private static func offlineRules() async throws -> WKContentRuleList {
        if let compiledRules { return compiledRules }
        let rules = ["^https?:", "^wss?:", "^ftp:"].map { #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"# }
        guard let store = WKContentRuleListStore.default(),
              let list = try? await store.compileContentRuleList(
                  forIdentifier: "TaskLensPowerPointOffline", encodedContentRuleList: "[" + rules.joined(separator: ",") + "]")
        else { throw PowerPointRenderError.webViewFailed }
        compiledRules = list
        return list
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: One render at a time

    private static let gate = Gate()

    @MainActor
    private final class Gate {
        private var busy = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            guard busy else {
                busy = true
                return
            }
            await withCheckedContinuation { waiting.append($0) }
        }

        func release() {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        }
    }

    fileprivate static func webViewOpened() {
        liveWebViewCount += 1
        peakWebViewCount = max(peakWebViewCount, liveWebViewCount)
    }

    fileprivate static func webViewClosed() { liveWebViewCount -= 1 }

    fileprivate static func recordFailure(_ detail: String) { lastFailureDetail = detail }

    /// The last snapshot thrown away because WebKit hadn't finished painting, and where.
    @_spi(Testing) public static var lastUnpaintedSnapshot: Data? { lastUnpaintedImage.flatMap { UIImage(cgImage: $0).pngData() } }
    @_spi(Testing) public private(set) static var lastUnpaintedArea: String?
    private static var lastUnpaintedImage: CGImage?

    fileprivate static func recordUnpainted(_ image: CGImage, area: String) {
        lastUnpaintedImage = image
        lastUnpaintedArea = area
    }
}

// MARK: - The web view

/// A hidden, offline web view holding one deck, behind the app's window.
@MainActor
private final class WebSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    struct Layout {
        /// Each `div.slide` in document coordinates (CSS pixels).
        var rects: [CGRect]
        var slideSize: CGSize
        var brokenImages: Int
        var directionFixApplied: Bool
    }

    struct Shot: Sendable {
        var data: Data
        var width: Int
        var height: Int
        var unpainted: Bool
        var retries = 0
        /// The 64 × 36 grid the page color check looked at.
        var fingerprint: [UInt8] = []
    }

    /// The A8 direction fix, plus hiding WebKit's static "Loading…" placeholders.
    /// Also paints the page magenta (`pageColor`) so unpainted areas can be told from slides.
    static let style = "p { unicode-bidi: plaintext; } div.loading-slide { display: none !important; } "
        + "html, body { margin: 0 !important; background: rgb(254, 0, 254) !important; } "
        // PowerPoint's default: a slide with no fill of its own is white.
        + "div.slide { background-color: #fff; }"

    private let deck: PowerPointDeck
    private let deadline: ContinuousClock.Instant
    private let window: UIWindow
    private let webView: WKWebView
    private let screenScale: CGFloat
    private var source: URL?
    private var mainNavigation: WKNavigation?
    private var finished = false
    private var failure: PowerPointRenderError?
    private var closed = false
    private(set) var blockedNavigations = 0

    init(deck: PowerPointDeck, scene: UIWindowScene, rules: WKContentRuleList, deadline: ContinuousClock.Instant) {
        self.deck = deck
        self.deadline = deadline
        screenScale = scene.screen.scale

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isTextInteractionEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsInlineMediaPlayback = false
        configuration.allowsPictureInPictureMediaPlayback = false
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.dataDetectorTypes = []
        configuration.userContentController.add(rules)

        // The slide is drawn at about 1000 points wide (2000+ pixels), so 1920-pixel
        // images are never upscaled; tall decks are fitted to the screen height.
        let aspect = deck.aspectRatio
        var size = CGSize(width: 1000, height: 1000 / aspect)
        let maximumHeight = scene.screen.bounds.height
        if size.height > maximumHeight { size = CGSize(width: maximumHeight * aspect, height: maximumHeight) }
        let frame = CGRect(origin: .zero, size: CGSize(width: ceil(size.width), height: ceil(size.height) + 2))

        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.allowsLinkPreview = false
        let pageColor = UIColor(red: 254 / 255, green: 0, blue: 254 / 255, alpha: 1)
        webView.underPageBackgroundColor = pageColor
        webView.backgroundColor = pageColor
        webView.scrollView.backgroundColor = pageColor
        webView.allowsBackForwardNavigationGestures = false
        webView.isUserInteractionEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false

        // Behind the app's window, never key, ignored by touch and VoiceOver.
        let window = UIWindow(windowScene: scene)
        window.frame = frame
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.isUserInteractionEnabled = false
        window.accessibilityElementsHidden = true
        window.addSubview(webView)
        self.webView = webView
        self.window = window
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.isHidden = false
        PowerPointRenderer.webViewOpened()
    }

    func close() {
        guard !closed else { return }
        closed = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        window.isHidden = true
        PowerPointRenderer.webViewClosed()
    }

    // MARK: Loading

    func load(_ url: URL) async throws {
        source = url
        mainNavigation = webView.loadFileURL(url, allowingReadAccessTo: url)
        while !finished {
            if let failure { throw failure }
            try await tick()
        }
    }

    /// Waits until WebKit has laid out every slide, pictures are decoded and fonts are ready.
    func waitForSlides() async throws -> Layout {
        let script = """
        (() => {
          const d = document;
          if (!d.getElementById('tasklens-pptx') && d.head) {
            const s = d.createElement('style'); s.id = 'tasklens-pptx'; s.textContent = '\(Self.style)'; d.head.appendChild(s);
          }
          const slides = Array.from(d.querySelectorAll('div.slide'));
          const images = Array.from(d.images);
          // WebKit draws large pictures only once a background decode ends; a snapshot
          // taken before that shows the slide without them.
          images.forEach(i => { if (i.decoding !== 'sync') { i.decoding = 'sync'; } });
          const p = d.querySelector('div.slide p');
          return JSON.stringify({
            complete: d.readyState === 'complete' && (!d.fonts || d.fonts.status === 'loaded'),
            pending: images.filter(i => !i.complete).length,
            broken: images.filter(i => i.complete && i.naturalWidth === 0).length,
            bidi: p ? getComputedStyle(p).unicodeBidi : 'plaintext',
            rects: slides.map(e => { const r = e.getBoundingClientRect(); return [r.left + scrollX, r.top + scrollY, r.width, r.height]; })
          });
        })()
        """
        struct State: Decodable { var complete: Bool; var pending: Int; var broken: Int; var bidi: String; var rects: [[Double]] }

        let expected = Set([deck.slides.count, deck.visibleSlides.count])
        var lastCount = -1, stablePolls = 0
        while true {
            if let failure { throw failure }
            let json = try await evaluate(script)
            guard let state = try? JSONDecoder().decode(State.self, from: Data(json.utf8)) else {
                throw PowerPointRenderError.renderingFailed(.slideCountMismatch(expected: deck.visibleSlides.count, rendered: 0))
            }
            stablePolls = state.rects.count == lastCount ? stablePolls + 1 : 0
            lastCount = state.rects.count
            let settled = state.complete && state.pending == 0
            if settled, stablePolls >= 2, expected.contains(state.rects.count) {
                let rects = state.rects.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
                return Layout(rects: rects, slideSize: rects.first?.size ?? .zero, brokenImages: state.broken,
                              directionFixApplied: state.bidi == "plaintext")
            }
            // Nothing has changed for three seconds and the count is still wrong.
            if settled, stablePolls >= 30 {
                throw PowerPointRenderError.renderingFailed(
                    .slideCountMismatch(expected: deck.visibleSlides.count, rendered: state.rects.count))
            }
            try await tick()
        }
    }

    /// Requests the page made to anything but the file and WebKit's own local scheme.
    func externalRequestCount() async throws -> Int {
        let json = try await evaluate("JSON.stringify(performance.getEntriesByType('resource').map(e => e.name.split(':')[0].toLowerCase()))")
        let schemes = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
        return schemes.filter { !["file", "x-apple-ql-id", "data", "blob", "about"].contains($0) }.count
    }

    // MARK: Snapshots

    func snapshot(_ cssRect: CGRect, webIndex: Int, slide: Int, deckAspect: Double, longestSidePixels: Int,
                  format: PowerPointRenderer.ImageFormat) async throws -> Shot {
        let scrollView = webView.scrollView
        let zoom = scrollView.zoomScale
        let target = CGPoint(x: cssRect.minX * zoom, y: cssRect.minY * zoom)
        scrollView.setContentOffset(target, animated: false)
        let pictureCount = try await decodePictures(onSlide: webIndex)
        let offset = scrollView.contentOffset

        let rect = CGRect(x: target.x - offset.x, y: target.y - offset.y, width: cssRect.width * zoom, height: cssRect.height * zoom)
        // A slide that doesn't fit in the view would come out cropped.
        guard webView.bounds.insetBy(dx: -1, dy: -1).contains(rect) else {
            PowerPointRenderer.recordFailure("slide \(slide) rect \(rect) bounds \(webView.bounds) zoom \(zoom)")
            throw PowerPointRenderError.renderingFailed(.snapshotFailed(slide: slide))
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        let pixelWidth = deckAspect >= 1 ? Double(longestSidePixels) : Double(longestSidePixels) * deckAspect
        configuration.snapshotWidth = NSNumber(value: pixelWidth / Double(screenScale))
        configuration.afterScreenUpdates = true

        // WebKit paints a newly scrolled-in area in tiles, a little later. Where it
        // hasn't painted yet the page color shows, so a snapshot with that color in
        // it is taken again rather than kept.
        // A picture still being drawn leaves no page color, only a gap, so a slide
        // with pictures is kept once two snapshots in a row look the same.
        var previous: [UInt8]?
        for attempt in 0..<Self.snapshotAttempts {
            if attempt > 0 { try await pause(.milliseconds(50 * attempt)) }
            var shot = try await capture(configuration, slide: slide, format: format)
            shot.retries = attempt
            if shot.unpainted { continue }
            if pictureCount == 0 || shot.fingerprint == previous { return shot }
            previous = shot.fingerprint
        }
        PowerPointRenderer.recordFailure("slide \(slide) was not fully painted or settled after \(Self.snapshotAttempts) snapshots: "
            + "\(PowerPointRenderer.lastUnpaintedArea ?? "-") rect \(rect) bounds \(webView.bounds) zoom \(zoom) "
            + "offset \(scrollView.contentOffset) content \(scrollView.contentSize) css \(cssRect)")
        throw PowerPointRenderError.renderingFailed(.snapshotFailed(slide: slide))
    }

    private static let snapshotAttempts = 6

    /// Waits until every picture on the slide is decoded, so none is captured empty.
    @discardableResult
    private func decodePictures(onSlide index: Int) async throws -> Int {
        let script = """
        (() => {
          const slide = document.querySelectorAll('div.slide')[\(index)];
          const images = slide ? Array.from(slide.querySelectorAll('img')) : [];
          images.forEach(i => {
            if (!i.dataset.tlDecode) {
              i.dataset.tlDecode = 'pending';
              i.decode().then(() => { i.dataset.tlDecode = 'done'; }, () => { i.dataset.tlDecode = 'done'; });
            }
          });
          return images.every(i => i.dataset.tlDecode === 'done') ? String(images.length) : 'waiting';
        })()
        """
        var answer = try await evaluate(script)
        while answer == "waiting" {
            try await pause(.milliseconds(20))
            answer = try await evaluate(script)
        }
        // One more round trip so the decoded pictures reach the screen.
        _ = try await evaluate("''")
        return Int(answer) ?? 0
    }

    private func capture(_ configuration: WKSnapshotConfiguration, slide: Int,
                         format: PowerPointRenderer.ImageFormat) async throws -> Shot {
        let waiter = Waiter<Shot>()
        webView.takeSnapshot(with: configuration) { image, _ in
            guard let image = image?.cgImage else {
                waiter.finish(.failure(PowerPointRenderError.renderingFailed(.snapshotFailed(slide: slide))))
                return
            }
            let pageColor = Self.pageColorArea(image)
            if pageColor.count >= 3 {
                PowerPointRenderer.recordUnpainted(image, area: pageColor.description)
                waiter.finish(.success(Shot(data: Data(), width: 0, height: 0, unpainted: true)))
                return
            }
            let trimmed = Self.trimmingPageColorEdges(image)
            let encoded: Data? = switch format {
            case .png: UIImage(cgImage: trimmed).pngData()
            case .jpeg(let quality): UIImage(cgImage: trimmed).jpegData(compressionQuality: quality)
            }
            guard let encoded else {
                waiter.finish(.failure(PowerPointRenderError.renderingFailed(.snapshotFailed(slide: slide))))
                return
            }
            waiter.finish(.success(Shot(data: encoded, width: trimmed.width, height: trimmed.height, unpainted: false,
                                        fingerprint: pageColor.grid)))
        }
        return try await wait(for: waiter)
    }

    /// The page and under-page color: a magenta no deck is expected to use.
    static let pageColor = (red: 254, green: 0, blue: 254)

    /// The slide's rect can reach a few points past its edge into the page.
    /// Rows and columns of page color along the edges are cut off and the
    /// rest is scaled back to the full size, so no magenta line is kept.
    static func trimmingPageColorEdges(_ image: CGImage) -> CGImage {
        let width = image.width, height = image.height
        guard width > 8, height > 8, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return image }

        func isPage(_ x: Int, _ y: Int) -> Bool {
            let offset = (y * width + x) * 4
            return pixels[offset] > 200 && pixels[offset + 1] < 80 && pixels[offset + 2] > 200
        }
        func rowIsPage(_ y: Int) -> Bool {
            stride(from: 0, to: width, by: 4).filter { isPage($0, y) }.count * 8 > width
        }
        func columnIsPage(_ x: Int) -> Bool {
            stride(from: 0, to: height, by: 4).filter { isPage(x, $0) }.count * 8 > height
        }
        let maximumRows = max(2, height / 50), maximumColumns = max(2, width / 50)
        var top = 0, bottom = height - 1, left = 0, right = width - 1
        while top < maximumRows, rowIsPage(top) { top += 1 }
        while height - 1 - bottom < maximumRows, rowIsPage(bottom) { bottom -= 1 }
        while left < maximumColumns, columnIsPage(left) { left += 1 }
        while width - 1 - right < maximumColumns, columnIsPage(right) { right -= 1 }
        guard top > 0 || left > 0 || bottom < height - 1 || right < width - 1 else { return image }
        // One more line on each trimmed side takes the blended edge too.
        if top > 0 { top += 1 }
        if left > 0 { left += 1 }
        if bottom < height - 1 { bottom -= 1 }
        if right < width - 1 { right -= 1 }

        guard let cropped = image.cropping(to: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Where the page color shows on a 64 × 36 grid of the image, edges left out.
    struct PageColorArea: CustomStringConvertible {
        var grid: [UInt8] = []
        var count = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        var description: String { "\(count) of 64x36 cells, x \(minX)...\(maxX), y \(minY)...\(maxY)" }
    }

    static func pageColorArea(_ image: CGImage) -> PageColorArea {
        let width = 64, height = 36
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return PageColorArea() }
        // Rounded to 32 levels so the same picture always gives the same grid.
        var area = PageColorArea(grid: pixels.map { $0 / 8 })
        for offset in stride(from: 0, to: pixels.count, by: 4)
        where abs(Int(pixels[offset]) - pageColor.red) < 16 && Int(pixels[offset + 1]) < 16
            && abs(Int(pixels[offset + 2]) - pageColor.blue) < 16 {
            let x = offset / 4 % width, y = offset / 4 / width
            // The outer cells can catch a sliver of page at a rounded slide edge.
            guard x > 0, y > 0, x < width - 1, y < height - 1 else { continue }
            area.count += 1
            area.minX = min(area.minX, x)
            area.maxX = max(area.maxX, x)
            area.minY = min(area.minY, y)
            area.maxY = max(area.maxY, y)
        }
        return area
    }

    // MARK: Time limits

    private func evaluate(_ script: String) async throws -> String {
        let waiter = Waiter<String>()
        webView.evaluateJavaScript(script) { value, error in
            if error != nil {
                waiter.finish(.failure(PowerPointRenderError.webViewFailed))
            } else {
                waiter.finish(.success(value as? String ?? ""))
            }
        }
        return try await wait(for: waiter)
    }

    /// Waits for WebKit's answer, but never past the deadline or a cancellation.
    private func wait<Value: Sendable>(for waiter: Waiter<Value>) async throws -> Value {
        let remaining = deadline - ContinuousClock.now
        let timer = Task {
            guard (try? await Task.sleep(for: remaining)) != nil else { return }
            waiter.finish(.failure(PowerPointRenderError.timeout))
        }
        defer { timer.cancel() }
        return try await waiter.value()
    }

    private func tick() async throws {
        try await pause(.milliseconds(100))
    }

    private func pause(_ duration: Duration) async throws {
        guard ContinuousClock.now < deadline else { throw PowerPointRenderError.timeout }
        try await Task.sleep(for: duration)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, navigationAction.targetFrame != nil else {
            blockedNavigations += 1
            return .cancel
        }
        if url.isFileURL, url.standardizedFileURL.path == source?.standardizedFileURL.path { return .allow }
        if url.scheme == "x-apple-ql-id" || url.absoluteString == "about:blank" { return .allow }
        blockedNavigations += 1
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if navigation === mainNavigation { finished = true }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        loadFailed(navigation, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        loadFailed(navigation, error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failure = failure ?? .webViewFailed
    }

    private func loadFailed(_ navigation: WKNavigation?, _ error: any Error) {
        // A blocked link or redirect fails on its own; only the deck's load matters.
        guard navigation === mainNavigation, !finished else { return }
        PowerPointRenderer.recordFailure("\((error as NSError).domain) \((error as NSError).code)")
        // OfficeImport refuses some valid decks, such as ones with speaker notes (A8).
        failure = (error as NSError).domain.contains("OfficeImport") ? .unsupportedContent : .webViewFailed
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }
}

/// A one-time answer from WebKit, a timer or a cancellation, whichever comes first.
private final class Waiter<Value: Sendable>: Sendable {
    private enum State: Sendable {
        case idle
        case waiting(CheckedContinuation<Value, any Error>)
        case finished(Result<Value, any Error>)
        case done
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: .idle)

    func finish(_ result: Result<Value, any Error>) {
        let continuation: CheckedContinuation<Value, any Error>? = state.withLock { state in
            switch state {
            case .idle:
                state = .finished(result)
                return nil
            case .waiting(let continuation):
                state = .done
                return continuation
            case .finished, .done:
                return nil
            }
        }
        continuation?.resume(with: result)
    }

    func value() async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                let ready: Result<Value, any Error>? = state.withLock { state in
                    if case .finished(let result) = state {
                        state = .done
                        return result
                    }
                    state = .waiting(continuation)
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            finish(.failure(PowerPointRenderError.cancelled))
        }
    }
}

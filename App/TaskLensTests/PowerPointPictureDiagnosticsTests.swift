import Foundation
import Testing
import UIKit
import WebKit

/// A9.5.6 diagnosis: on the 80-picture acceptance deck, rendered slides showed
/// other slides' pictures. This loads the deck the way the renderer does and,
/// for every slide, prints which picture the page links, which picture the
/// page's image actually holds, and which picture a snapshot shows, under a
/// few settings. `PPTX A956DIAG` lines carry the results. Not a check.
@MainActor
@Suite("A9.5.6 picture diagnostics", .serialized)
struct PowerPointPictureDiagnosticsTests {
    /// The deck's picture colors: slide n's picture is `colors[n % 6]`.
    nonisolated private static let colors: [(Int, Int, Int)] = [
        (0x1f, 0x6f, 0xeb), (0xd1, 0x24, 0x2f), (0x1a, 0x7f, 0x37), (0x82, 0x50, 0xdf), (0xbf, 0x87, 0x00), (0x0a, 0x30, 0x69),
    ]

    enum Mode: String, CaseIterable, Sendable { case rendererLike, asyncDecoding, slowSnapshots }

    @Test(arguments: Mode.allCases)
    func whichPictureEachSlideShows(mode: Mode) async throws {
        let bundle = Bundle(for: DiagnosticsToken.self)
        let deck = try #require(bundle.url(forResource: "acceptance-6-large-80-slides", withExtension: "pptx")
            ?? bundle.url(forResource: "acceptance-6-large-80-slides", withExtension: "pptx", subdirectory: "Fixtures"))
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("A956Diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let copy = work.appendingPathComponent("deck.pptx")
        try FileManager.default.copyItem(at: deck, to: copy)

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let frame = CGRect(x: 0, y: 0, width: 1000, height: ceil(1000 / (16.0 / 9.0)) + 2)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        let window = UIWindow(windowScene: scene)
        window.frame = frame
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.addSubview(webView)
        window.isHidden = false
        defer { webView.removeFromSuperview(); window.isHidden = true }

        let loader = Loader()
        webView.navigationDelegate = loader
        webView.loadFileURL(copy, allowingReadAccessTo: copy)
        let deadline = ContinuousClock.now + .seconds(120)
        while !loader.finished, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(loader.finished)

        // The renderer's wait: every slide laid out and every image complete.
        let syncDecoding = mode != .asyncDecoding
        var rects: [[Double]] = []
        for _ in 0..<600 {
            let json = try await evaluate(webView, """
            (() => {
              const s = document.createElement('style');
              s.textContent = 'div.loading-slide { display: none !important; } html, body { margin: 0 !important; } div.slide { background-color: #fff; }';
              if (!document.getElementById('diag')) { s.id = 'diag'; document.head.appendChild(s); }
              const images = Array.from(document.images);
              if (\(syncDecoding)) images.forEach(i => { i.decoding = 'sync'; });
              const slides = Array.from(document.querySelectorAll('div.slide'));
              const ready = document.readyState === 'complete' && images.every(i => i.complete);
              return JSON.stringify({ ready, rects: slides.map(e => { const r = e.getBoundingClientRect(); return [r.left + scrollX, r.top + scrollY, r.width, r.height]; }) });
            })()
            """)
            struct State: Decodable { var ready: Bool; var rects: [[Double]] }
            let state = try JSONDecoder().decode(State.self, from: Data(json.utf8))
            if state.ready, state.rects.count == 80 { rects = state.rects; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(rects.count == 80, "80 slides laid out")

        var linked = 0, held = 0, shown = 0
        for index in 0..<80 {
            let number = index + 1
            // What the page links and what its image holds (drawn into a canvas).
            let info = try await evaluate(webView, """
            (() => {
              const slide = document.querySelectorAll('div.slide')[\(index)];
              const images = Array.from(slide.querySelectorAll('img'));
              const bg = Array.from(slide.querySelectorAll('*')).map(e => getComputedStyle(e).backgroundImage).filter(b => b && b !== 'none');
              return JSON.stringify(images.map(i => {
                let color = 'none';
                try {
                  const c = document.createElement('canvas'); c.width = 16; c.height = 9;
                  const g = c.getContext('2d'); g.drawImage(i, 0, 0, 16, 9);
                  const d = g.getImageData(4, 3, 1, 1).data; color = [d[0], d[1], d[2]].join(',');
                } catch (e) { color = 'error:' + e.name; }
                return { src: (i.currentSrc || i.src).split('/').slice(-2).join('/'), w: i.naturalWidth, color };
              }).concat(bg.map(b => ({ src: 'background ' + b.slice(0, 80), w: 0, color: 'none' }))));
            })()
            """)
            struct Picture: Decodable { var src: String; var w: Int; var color: String }
            let pictures = (try? JSONDecoder().decode([Picture].self, from: Data(info.utf8))) ?? []

            // What a snapshot of the slide shows.
            let zoom = webView.scrollView.zoomScale
            let rect = rects[index]
            webView.scrollView.setContentOffset(CGPoint(x: rect[0] * zoom, y: rect[1] * zoom), animated: false)
            if mode == .slowSnapshots { try await Task.sleep(for: .milliseconds(600)) }
            _ = try await evaluate(webView, """
            Promise.all(Array.from(document.querySelectorAll('div.slide')[\(index)].querySelectorAll('img')).map(i => i.decode().catch(() => 0))).then(() => '')
            """, awaitPromise: true)
            let offset = webView.scrollView.contentOffset
            let snapshotConfiguration = WKSnapshotConfiguration()
            snapshotConfiguration.rect = CGRect(x: rect[0] * zoom - offset.x, y: rect[1] * zoom - offset.y,
                                                width: rect[2] * zoom, height: rect[3] * zoom)
            snapshotConfiguration.afterScreenUpdates = true
            let snapshotColor: (Int, Int, Int)? = try await withCheckedThrowingContinuation { continuation in
                webView.takeSnapshot(with: snapshotConfiguration) { image, error in
                    if let image {
                        continuation.resume(returning: image.cgImage.flatMap { Self.color(in: $0, x: 0.25, y: 0.30) })
                    } else {
                        continuation.resume(throwing: error ?? CancellationError())
                    }
                }
            }

            let expected = number % 6
            let linkedNumber = pictures.first.flatMap { Int($0.src.filter(\.isNumber)) }
            let heldIndex = pictures.first.flatMap { Self.parse($0.color) }.map(Self.nearest)
            let shownIndex = snapshotColor.map(Self.nearest)
            if linkedNumber.map({ $0 % 6 }) == expected || linkedNumber == number { linked += 1 }
            if heldIndex == expected { held += 1 }
            if shownIndex == expected { shown += 1 }
            print("PPTX A956DIAG \(mode.rawValue) slide \(number): pictures=\(pictures.count) linked=\(pictures.first?.src ?? "-") "
                + "w=\(pictures.first?.w ?? 0) held=\(pictures.first?.color ?? "-")→\(heldIndex.map(String.init) ?? "?") "
                + "shown=\(shownIndex.map(String.init) ?? "?") expected=\(expected)"
                + (pictures.count > 1 ? " more=\(pictures.dropFirst().map(\.src))" : ""))
        }
        print("PPTX A956DIAG \(mode.rawValue) summary: linkedOK=\(linked)/80 heldOK=\(held)/80 shownOK=\(shown)/80 zoom=\(webView.scrollView.zoomScale)")
    }

    // MARK: Helpers

    private func evaluate(_ webView: WKWebView, _ script: String, awaitPromise: Bool = false) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            if awaitPromise {
                webView.callAsyncJavaScript("return await (\(script));", arguments: [:], in: nil, in: .defaultClient) { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: value as? String ?? "")
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            } else {
                webView.evaluateJavaScript(script) { value, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: value as? String ?? "") }
                }
            }
        }
    }

    nonisolated private static func parse(_ text: String) -> (Int, Int, Int)? {
        let parts = text.split(separator: ",").compactMap { Int($0) }
        return parts.count == 3 ? (parts[0], parts[1], parts[2]) : nil
    }

    nonisolated private static func nearest(_ color: (Int, Int, Int)) -> Int {
        colors.indices.min { a, b in distance(colors[a], color) < distance(colors[b], color) } ?? 0
    }

    nonisolated private static func distance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
        (a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)
    }

    /// The color at a point given as fractions of the image's width and height.
    nonisolated private static func color(in image: CGImage, x: Double, y: Double) -> (Int, Int, Int)? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let px = Double(image.width) * x, py = Double(image.height) * y
        context.draw(image, in: CGRect(x: -px, y: -(Double(image.height) - py - 1), width: Double(image.width), height: Double(image.height)))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }
}

@MainActor
private final class Loader: NSObject, WKNavigationDelegate {
    var finished = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finished = true }
}

private final class DiagnosticsToken {}

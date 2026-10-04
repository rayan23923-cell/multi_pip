import PDFKit
import QuickLook
import QuickLookThumbnailing
import UIKit
import WebKit
import XCTest

/// A8 probe: what the public iOS APIs do with .pptx files. Every result is
/// printed as a `PROBE` line; images are printed base64 as `PROBEIMG` lines so
/// they can be read back from the CI log. Nothing here asserts on rendering.
@MainActor
final class PPTXProbeTests: XCTestCase {
    private var decks: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["PPTX_DIR"] ?? "/missing")
    }

    // MARK: Quick Look

    func test1QuickLookThumbnail() async throws {
        for name in ["audit.pptx", "macro.pptm", "garbage.pptx", "xxe.pptx", "zipbomb.pptx", "scale-100.pptx"] {
            let url = decks.appendingPathComponent(name)
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: 960, height: 540), scale: 1, representationTypes: .thumbnail
            )
            let started = Date()
            do {
                let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
                let image = representation.uiImage
                log("QLTHUMB \(name) ok type=\(representation.type.rawValue) size=\(image.size) "
                    + "time=\(seconds(since: started)) colors=\(distinctColors(image))")
                if name == "audit.pptx" || name == "xxe.pptx" { emit("qlthumb-\(name)", image, width: 960) }
            } catch {
                log("QLTHUMB \(name) error=\(error) time=\(seconds(since: started))")
            }
        }
    }

    func test2QuickLookPreviewController() async throws {
        let window = try await hostWindow()
        for name in ["audit.pptx", "macro.pptm", "garbage.pptx"] {
            let url = decks.appendingPathComponent(name)
            log("QLPREVIEW \(name) canPreview=\(QLPreviewController.canPreview(url as NSURL))")
        }
        let source = PreviewSource(url: decks.appendingPathComponent("audit.pptx"))
        let preview = QLPreviewController()
        preview.dataSource = source
        let started = Date()
        window.rootViewController?.present(preview, animated: false)
        try await Task.sleep(nanoseconds: 6_000_000_000)
        log("QLPREVIEW audit.pptx presented after=\(seconds(since: started)) "
            + "subviews=\(countViews(preview.view)) footprintMB=\(footprintMB())")
        emit("qlpreview-window", snapshot(window), width: 414)
        preview.dismiss(animated: false)
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    // MARK: WebKit

    func test3WebViewAuditDeck() async throws {
        let window = try await hostWindow()
        let url = decks.appendingPathComponent("audit.pptx")
        let (web, delegate) = makeWebView(in: window, width: 414)
        let before = footprintMB()
        let started = Date()
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        try await waitForLoad(web, delegate, timeout: 120)
        log("WEB audit.pptx finished=\(delegate.finished) error=\(String(describing: delegate.error)) "
            + "crashed=\(delegate.crashed) time=\(seconds(since: started)) appFootprintMB \(before)->\(footprintMB())")
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let dom = try await evaluate(web, Self.domSummary)
        log("WEBDOM audit.pptx \(dom)")
        let head = try await evaluate(web, "document.documentElement.outerHTML.slice(0, 6000)")
        for (index, chunk) in chunks(head, 1500).enumerated() { log("WEBHTML \(index) \(chunk)") }

        // Whole document at 414 pt wide (iPhone 11), then the PDF WebKit makes of it.
        let height = try await evaluate(web, "document.documentElement.scrollHeight")
        let contentHeight = CGFloat(Double(height) ?? 896)
        web.frame.size.height = min(contentHeight, 16_000)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 600
        let shot = try await web.takeSnapshot(configuration: config)
        log("WEBSNAP size=\(shot.size) contentHeight=\(contentHeight)")
        emit("web-full", shot, width: 600)

        // One slide at a time, using WebKit's own layout (div.slide, if present).
        let rects = try await evaluate(web, """
        JSON.stringify(Array.from(document.querySelectorAll('div.slide')).map(e => {
          const r = e.getBoundingClientRect(); return [r.x + scrollX, r.y + scrollY, r.width, r.height];
        }))
        """)
        log("WEBSLIDES rects=\(rects)")
        if let data = rects.data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[Double]] {
            for index in [0, 8, 9, 13] where index < list.count {
                let r = list[index]
                let slideConfig = WKSnapshotConfiguration()
                slideConfig.rect = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
                slideConfig.snapshotWidth = 900
                let started = Date()
                let image = try await web.takeSnapshot(configuration: slideConfig)
                log("WEBSLIDESNAP \(index + 1) size=\(image.size) time=\(seconds(since: started))")
                emit("web-slide-\(index + 1)", image, width: 900)
            }
        }

        let pdfStarted = Date()
        let pdfData = try await web.pdf(configuration: WKPDFConfiguration())
        let document = PDFDocument(data: pdfData)
        log("WEBPDF bytes=\(pdfData.count) pages=\(document?.pageCount ?? -1) "
            + "page0=\(document?.page(at: 0)?.bounds(for: .mediaBox) ?? .zero) time=\(seconds(since: pdfStarted))")

        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(web.viewPrintFormatter(), startingAtPageAt: 0)
        let paper = CGRect(x: 0, y: 0, width: 960, height: 540)
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: paper), forKey: "printableRect")
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: 1))
        log("WEBPRINT pages at 960x540 = \(renderer.numberOfPages)")
        web.removeFromSuperview()
    }

    func test4WebViewScaleAndHostileFiles() async throws {
        let window = try await hostWindow()
        let names = ["scale-10.pptx", "scale-50.pptx", "scale-100.pptx",
                     "macro.pptm", "garbage.pptx", "xxe.pptx", "zipbomb.pptx"]
        for name in names {
            let url = decks.appendingPathComponent(name)
            let (web, delegate) = makeWebView(in: window, width: 414)
            let before = footprintMB()
            let started = Date()
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            try await waitForLoad(web, delegate, timeout: 180)
            let elapsed = seconds(since: started)
            var dom = "unavailable"
            if delegate.finished { dom = (try? await evaluate(web, Self.domSummary)) ?? "eval failed" }
            log("WEB \(name) finished=\(delegate.finished) error=\(String(describing: delegate.error)) "
                + "crashed=\(delegate.crashed) time=\(elapsed) appFootprintMB \(before)->\(footprintMB()) dom=\(dom)")
            if name == "xxe.pptx", delegate.finished {
                let text = (try? await evaluate(web, "document.body ? document.body.innerText.slice(0, 400) : ''")) ?? ""
                log("WEBXXE text=\(text.replacingOccurrences(of: "\n", with: " | "))")
            }
            web.removeFromSuperview()
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: Helpers

    private static let domSummary = """
    (() => {
      const b = document.body;
      const tops = b ? Array.from(b.children).slice(0, 12).map(e => {
        const r = e.getBoundingClientRect();
        return e.tagName + (e.className ? '.' + e.className : '') + ' ' + Math.round(r.width) + 'x' + Math.round(r.height);
      }) : [];
      const text = b ? b.innerText : '';
      return JSON.stringify({
        title: document.title, contentType: document.contentType,
        elements: document.getElementsByTagName('*').length,
        images: document.images.length, svgs: document.getElementsByTagName('svg').length,
        canvases: document.getElementsByTagName('canvas').length,
        links: Array.from(document.links).map(a => a.href).slice(0, 5),
        scroll: [document.documentElement.scrollWidth, document.documentElement.scrollHeight],
        hasArabic: /[\\u0600-\\u06FF]/.test(text), hasNotes: text.includes('Speaker note'),
        dirRTL: Array.from(document.querySelectorAll('[dir=rtl]')).length,
        slides: document.querySelectorAll('div.slide').length,
        slideRects: Array.from(document.querySelectorAll('div.slide')).slice(0, 3).map(e => {
          const r = e.getBoundingClientRect(); return [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)];
        }),
        textStart: text.slice(0, 300), tops
      });
    })()
    """

    private func makeWebView(in window: UIWindow, width: CGFloat) -> (WKWebView, NavigationProbe) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 896), configuration: config)
        let delegate = NavigationProbe()
        web.navigationDelegate = delegate
        objc_setAssociatedObject(web, &NavigationProbe.key, delegate, .OBJC_ASSOCIATION_RETAIN)
        window.addSubview(web)
        return (web, delegate)
    }

    private func waitForLoad(_ web: WKWebView, _ delegate: NavigationProbe, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !delegate.finished && delegate.error == nil && !delegate.crashed && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func evaluate(_ web: WKWebView, _ script: String) async throws -> String {
        let value: Any? = try await web.evaluateJavaScript(script)
        if let text = value as? String { return text }
        return value.map { "\($0)" } ?? "nil"
    }

    private func hostWindow() async throws -> UIWindow {
        for _ in 0..<50 {
            if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: { $0.rootViewController != nil }) {
                return window
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw XCTSkip("No host window")
    }

    private func log(_ line: String) { print("PROBE \(line)") }

    private func seconds(since date: Date) -> String { String(format: "%.2fs", Date().timeIntervalSince(date)) }

    private func chunks(_ text: String, _ size: Int) -> [String] {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return stride(from: 0, to: flat.count, by: size).map { start in
            let from = flat.index(flat.startIndex, offsetBy: start)
            let to = flat.index(from, offsetBy: min(size, flat.count - start))
            return String(flat[from..<to])
        }
    }

    private func emit(_ name: String, _ image: UIImage, width: CGFloat) {
        let scale = min(1, width / max(image.size.width, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = resized.jpegData(compressionQuality: 0.7) else { return }
        let encoded = data.base64EncodedString()
        let parts = stride(from: 0, to: encoded.count, by: 8000).map { start -> String in
            let from = encoded.index(encoded.startIndex, offsetBy: start)
            let to = encoded.index(from, offsetBy: min(8000, encoded.count - start))
            return String(encoded[from..<to])
        }
        for (index, part) in parts.enumerated() { print("PROBEIMG \(name) \(index)/\(parts.count) \(part)") }
    }

    private func snapshot(_ window: UIWindow) -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func countViews(_ view: UIView) -> Int { 1 + view.subviews.map(countViews).reduce(0, +) }

    /// Samples a grid of pixels; 1 means the image is blank.
    private func distinctColors(_ image: UIImage) -> Int {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return -1 }
        var seen = Set<UInt32>()
        let step = max(cg.bitsPerPixel / 8, 1)
        for y in stride(from: 0, to: cg.height, by: max(cg.height / 40, 1)) {
            for x in stride(from: 0, to: cg.width, by: max(cg.width / 40, 1)) {
                let offset = y * cg.bytesPerRow + x * step
                seen.insert(UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]))
            }
        }
        return seen.count
    }

    private func footprintMB() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? String(format: "%.0f", Double(info.phys_footprint) / 1_048_576) : "?"
    }
}

final class NavigationProbe: NSObject, WKNavigationDelegate {
    static var key = 0
    var finished = false
    var error: Error?
    var crashed = false
    var requests: [String] = []

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        requests.append(action.request.url?.absoluteString ?? "nil")
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.error = error }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { crashed = true }
}

final class PreviewSource: NSObject, QLPreviewControllerDataSource {
    let url: URL
    init(url: URL) { self.url = url }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewItem(at index: Int) -> QLPreviewItem { url as NSURL }
}

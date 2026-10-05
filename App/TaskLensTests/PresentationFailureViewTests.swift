import PresentationFeature
import SwiftUI
import Testing
import TLCoreServices
import UIKit

/// A9.5.2: the PowerPoint failure screen drawn in the app's window, as it
/// appears on an iPhone 11 (414 × 896 points): light and dark, English and
/// Arabic (right to left), default and accessibility text sizes. `PROBEIMG`
/// lines carry each drawing so it can be checked by eye from the log.
@MainActor
@Suite("PowerPoint failure screen drawing", .serialized)
struct PresentationFailureViewTests {
    struct Variant: Sendable, CustomTestStringConvertible {
        var name: String
        var language: String
        var dark: Bool
        var size: DynamicTypeSize
        var testDescription: String { name }
    }

    nonisolated static let variants = [
        Variant(name: "en-light", language: "en", dark: false, size: .large),
        Variant(name: "en-dark", language: "en", dark: true, size: .large),
        Variant(name: "ar-light", language: "ar", dark: false, size: .large),
        Variant(name: "ar-dark", language: "ar", dark: true, size: .large),
        Variant(name: "en-ax3", language: "en", dark: false, size: .accessibility3),
        Variant(name: "ar-ax3-dark", language: "ar", dark: true, size: .accessibility3),
    ]

    @Test(arguments: variants)
    func theScreenDrawsInEveryAppearance(_ variant: Variant) async throws {
        for failure in [PowerPointFailure.speakerNotesUnsupported, .renderingFailed] {
            let content = try #require(PowerPointFailureContent(failure))
            let image = try await draw(content, variant)
            let stats = luminance(image)
            if variant.dark {
                #expect(stats.mean < 0.25, "\(variant.name) \(failure): dark background, mean \(stats.mean)")
            } else {
                #expect(stats.mean > 0.75, "\(variant.name) \(failure): light background, mean \(stats.mean)")
            }
            #expect(stats.contrasting > 500, "\(variant.name) \(failure): text and buttons drawn (\(stats.contrasting) px)")
            emit("a952-\(failure)-\(variant.name)", image)
        }
    }

    // MARK: Helpers

    private func draw(_ content: PowerPointFailureContent, _ variant: Variant) async throws -> UIImage {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 414, height: 896)
        window.overrideUserInterfaceStyle = variant.dark ? .dark : .light
        let view = PresentationFailureView(content) { _ in }
            .environment(\.locale, Locale(identifier: variant.language))
            .environment(\.layoutDirection, variant.language == "ar" ? .rightToLeft : .leftToRight)
            .dynamicTypeSize(variant.size)
        let host = UIHostingController(rootView: view)
        host.view.backgroundColor = .systemBackground
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// Mean luminance, and how many pixels differ strongly from it (text, icons, buttons).
    private func luminance(_ image: UIImage) -> (mean: Double, contrasting: Int) {
        guard let cgImage = image.cgImage else { return (0, 0) }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return (0, 0) }
        var values: [Double] = []
        values.reserveCapacity(width * height)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            values.append((0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])) / 255)
        }
        let mean = values.reduce(0, +) / Double(max(values.count, 1))
        return (mean, values.filter { abs($0 - mean) > 0.35 }.count)
    }

    /// Prints a JPEG of the image, base64 in 8,000-character lines.
    private func emit(_ name: String, _ image: UIImage) {
        guard let encoded = image.jpegData(compressionQuality: 0.6)?.base64EncodedString() else { return }
        let parts = stride(from: 0, to: encoded.count, by: 8000).map { start in
            let from = encoded.index(encoded.startIndex, offsetBy: start)
            return String(encoded[from..<encoded.index(from, offsetBy: min(8000, encoded.count - start))])
        }
        for (index, part) in parts.enumerated() { print("PROBEIMG \(name) \(index)/\(parts.count) \(part)") }
    }
}

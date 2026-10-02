import AVFoundation
import CoreMedia
import CoreVideo
import SwiftUI
import TLDomain

/// Turns a card into one video frame (`CMSampleBuffer`), because Picture in
/// Picture can only show video. Frames are drawn on the device; nothing leaves it.
@MainActor
public struct PiPFrameRenderer {
    /// Pixels per point. 2 keeps text sharp in the largest window without large frames.
    public static let scale: CGFloat = 2

    public init() {}

    /// Appearance used to draw the frame.
    public struct Appearance: Equatable, Sendable {
        public var colorScheme: ColorScheme
        public var layoutDirection: LayoutDirection
        public var locale: Locale

        public init(colorScheme: ColorScheme = .light, layoutDirection: LayoutDirection = .leftToRight, locale: Locale = .current) {
            self.colorScheme = colorScheme
            self.layoutDirection = layoutDirection
            self.locale = locale
        }
    }

    public func image(for card: PiPCard?, position: Int, count: Int, appearance: Appearance) -> CGImage? {
        let content = PiPCardView(card: card, position: position, count: count)
            .environment(\.colorScheme, appearance.colorScheme)
            .environment(\.layoutDirection, appearance.layoutDirection)
            .environment(\.locale, appearance.locale)
        let renderer = ImageRenderer(content: content)
        renderer.scale = Self.scale
        renderer.proposedSize = ProposedViewSize(PiPCardView.size)
        renderer.isOpaque = true
        return renderer.cgImage
    }

    public func sampleBuffer(for card: PiPCard?, position: Int, count: Int, appearance: Appearance) -> CMSampleBuffer? {
        guard let image = image(for: card, position: position, count: count, appearance: appearance) else { return nil }
        return Self.sampleBuffer(from: image)
    }

    /// A frame shown as soon as it is enqueued, with no fixed duration: the
    /// card stays on screen until the next frame replaces it.
    public nonisolated static func sampleBuffer(from image: CGImage) -> CMSampleBuffer? {
        guard let pixelBuffer = pixelBuffer(from: image) else { return nil }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format
        ) == noErr, let format else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }

    nonisolated static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }
}

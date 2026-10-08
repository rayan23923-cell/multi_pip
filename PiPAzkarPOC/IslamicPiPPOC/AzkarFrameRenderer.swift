import UIKit
import CoreMedia
import CoreVideo

/// Draws Arabic text into a BGRA CVPixelBuffer and wraps it in a CMSampleBuffer
/// that AVSampleBufferDisplayLayer can show. PiP cannot host a SwiftUI/UIView,
/// so every visible change in the PiP window is a new video frame produced here.
enum AzkarFrameRenderer {
    // 16:9 frame. PiP takes its window aspect ratio from the video dimensions.
    static let width = 1280
    static let height = 720

    static func makePixelBuffer(text: String, footer: String) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // Flip to UIKit coordinates so NSAttributedString drawing is upright.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        UIColor(red: 0.05, green: 0.22, blue: 0.16, alpha: 1).setFill()
        UIRectFill(bounds)

        // Main Arabic line: RTL paragraph, centered, large. Core Text handles
        // Arabic shaping and harakat; the system font falls back to SF Arabic.
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.baseWritingDirection = .rightToLeft
        para.lineBreakMode = .byWordWrapping
        let main = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 110, weight: .bold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: para,
        ])
        let textRect = bounds.insetBy(dx: 60, dy: 80)
        let measured = main.boundingRect(with: textRect.size,
                                         options: [.usesLineFragmentOrigin, .usesFontLeading],
                                         context: nil)
        let y = textRect.minY + (textRect.height - measured.height) / 2
        main.draw(with: CGRect(x: textRect.minX, y: y, width: textRect.width, height: measured.height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)

        // Small footer with a clock so a tester can see frames still updating
        // while PiP floats over other apps.
        let footPara = NSMutableParagraphStyle()
        footPara.alignment = .center
        let foot = NSAttributedString(string: footer, attributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 34, weight: .regular),
            .foregroundColor: UIColor(white: 1, alpha: 0.7),
            .paragraphStyle: footPara,
        ])
        foot.draw(in: CGRect(x: 0, y: CGFloat(height) - 70, width: CGFloat(width), height: 50))

        return pb
    }

    static func makeSampleBuffer(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pixelBuffer,
                                                     formatDescriptionOut: &format)
        guard let format else { return nil }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 2),
                                        presentationTimeStamp: presentationTime,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: pixelBuffer,
                                                 formatDescription: format,
                                                 sampleTiming: &timing,
                                                 sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { return nil }

        // Show the frame as soon as it is enqueued instead of scheduling it.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }
}

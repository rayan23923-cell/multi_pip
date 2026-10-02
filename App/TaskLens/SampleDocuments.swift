import Foundation
import TLCoreServices
import UIKit
import UniformTypeIdentifiers

/// Generates a small PDF, text file and image for UI tests and previews.
/// Only used with the `-TaskLensSeedDocuments` launch argument.
enum SampleDocuments {
    static let launchArgument = "-TaskLensSeedDocuments"

    static func seedIfRequested(_ service: DocumentService, arguments: [String] = ProcessInfo.processInfo.arguments) async {
        guard arguments.contains(launchArgument),
              (try? await service.documents(in: nil).isEmpty) == true
        else { return }
        _ = try? await service.importData(pdf(), filename: "Sample Report.pdf", contentType: .pdf)
        _ = try? await service.importData(Data(text.utf8), filename: "Sample Notes.txt", contentType: .plainText)
        _ = try? await service.importData(image(), filename: "Sample Image.png", contentType: .png)
    }

    static let text = """
    TaskLens sample notes
    ملاحظات تجريبية لتطبيق TaskLens
    The budget review is on Monday.
    """

    /// Three pages; the word "invoice" appears only on page 2.
    static func pdf() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for page in 1...3 {
                context.beginPage()
                let body = page == 2 ? "Page \(page): invoice total 42" : "Page \(page): TaskLens sample"
                body.draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
    }

    static func image() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // A receipt-like picture with a price on it, for Lens to read.
        return UIGraphicsImageRenderer(size: CGSize(width: 480, height: 240), format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 240))
            UIColor.white.setFill()
            context.fill(CGRect(x: 40, y: 40, width: 400, height: 160))
            ("Total $125" as NSString).draw(
                at: CGPoint(x: 70, y: 90),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 44), .foregroundColor: UIColor.black]
            )
        }
    }
}

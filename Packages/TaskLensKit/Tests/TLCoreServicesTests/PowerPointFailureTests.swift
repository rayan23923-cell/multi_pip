import Foundation
import Testing
import TLCoreServices
import TLDomain
import TLFoundation

/// A9.5.1: how PowerPoint failures are classified. The renderer itself is
/// exercised in the app's tests; these check the mapping and the import check.
@Suite("PowerPoint failure classification")
struct PowerPointFailureTests {
    // MARK: Renderer errors

    @Test func everyRendererErrorHasOneCategory() {
        let cases: [(PowerPointRenderError, PowerPointFailure)] = [
            (.invalidPresentation, .invalidSource),
            (.unsupportedContent, .unsupportedPresentation),
            (.resourceMissing(part: "ppt/media/image1.png"), .missingResource),
            (.renderingFailed(.slideCountMismatch(expected: 100, rendered: 73)), .renderingFailed),
            (.renderingFailed(.slideSizeMismatch), .renderingFailed),
            (.renderingFailed(.noVisibleSlides), .renderingFailed),
            (.renderingFailed(.snapshotFailed(slide: 4)), .renderingFailed),
            (.renderingFailed(.writeFailed), .storageFailure),
            (.webViewFailed, .renderingFailed),
            (.timeout, .timeout),
            (.cancelled, .cancelled),
        ]
        for (error, expected) in cases {
            #expect(PowerPointFailure(error) == expected, "\(error)")
        }
    }

    /// Speaker notes are named only when OfficeImport's refusal code and the deck both say so.
    @Test func speakerNotesAreNeverGuessed() {
        let refusal = PowerPointFailure.officeImportRefusalCode
        #expect(PowerPointFailure(PowerPointRenderError.unsupportedContent, officeImportCode: refusal, hasSpeakerNotes: true)
            == .speakerNotesUnsupported)
        let notIdentified: [(Int?, Bool?)] = [
            (refusal, false), // refused, but no notes: something else
            (refusal, nil), // the deck could not be read to check
            (nil, true), // notes, but the code is unknown
            (refusal + 1, true), // notes, but another refusal
        ]
        for (code, notes) in notIdentified {
            #expect(PowerPointFailure(PowerPointRenderError.unsupportedContent, officeImportCode: code, hasSpeakerNotes: notes)
                == .unsupportedPresentation, "code \(String(describing: code)) notes \(String(describing: notes))")
        }
        // Notes never turn another failure into a notes failure.
        #expect(PowerPointFailure(PowerPointRenderError.webViewFailed, officeImportCode: refusal, hasSpeakerNotes: true) == .renderingFailed)
        #expect(PowerPointFailure(PowerPointRenderError.timeout, officeImportCode: refusal, hasSpeakerNotes: true) == .timeout)
    }

    @Test func otherErrors() {
        #expect(PowerPointFailure(CancellationError()) == .cancelled)
        #expect(PowerPointFailure(PowerPointFailure.corruptedCache) == .corruptedCache)
        #expect(PowerPointFailure(TaskLensError.validationFailed(.invalidPresentation)) == .invalidSource)
        #expect(PowerPointFailure(TaskLensError.notFound(entity: "Document", id: "x")) == .invalidSource)
        #expect(PowerPointFailure(TaskLensError.unsupportedContent(type: "pptx")) == .unsupportedPresentation)
        #expect(PowerPointFailure(TaskLensError.persistenceFailed(operation: .read, details: "x")) == .storageFailure)
        #expect(PowerPointFailure(TaskLensError.validationFailed(.emptyName)) == .unknown)
        #expect(PowerPointFailure(NSError(domain: "WKErrorDomain", code: 2)) == .unknown)
        #expect(PowerPointFailure(CocoaError(.fileReadCorruptFile)) == .unknown)
    }

    /// Until the failure screen (A9.5.2), the presentation shows what it showed in A9.3.
    @MainActor
    @Test func thePresentationPhaseIsUnchanged() async {
        let unsupported: Set<PowerPointFailure> = [.invalidSource, .unsupportedPresentation, .speakerNotesUnsupported, .securityRejected]
        for failure in PowerPointFailure.allCases {
            if failure == .cancelled {
                #expect(failure.presentationError is CancellationError)
                continue
            }
            let engine = PresentationEngine()
            #expect(!(await engine.load(from: Failing(error: failure.presentationError))))
            #expect(engine.phase == .error(unsupported.contains(failure) ? .unsupportedSource : .unreadable), "\(failure)")
            #expect(engine.document == nil)
        }
    }

    /// No category carries a file path, part name, WebKit code or other detail.
    @Test func categoriesCarryNoDetail() {
        #expect(PowerPointFailure.allCases.count == 11)
        let failure = PowerPointFailure(PowerPointRenderError.resourceMissing(part: "ppt/slides/slide7.xml"))
        #expect(!"\(failure)".contains("slide7"))
    }

    // MARK: Import check (A9.1)

    @Test func theImportCheckSaysWhyItRejects() {
        let expected: [String: PowerPointPackage.Rejection] = [
            "not a ZIP": .malformed,
            "PDF renamed .pptx": .malformed,
            "Word file renamed .pptx": .malformed,
            "ZIP without content types": .malformed,
            "macro project (.pptm renamed)": .unsafe,
            "path escaping the package": .unsafe,
            "absolute path": .unsafe,
            "ZIP bomb ratio": .unsafe,
            "ZIP bomb total": .unsafe,
            "cut short": .malformed,
            "only the local header": .malformed,
        ]
        #expect(Set(expected.keys) == Set(PowerPointImportTests.invalidFiles.map(\.0)))
        for (label, data) in PowerPointImportTests.invalidFiles {
            #expect(PowerPointPackage.rejection(of: data) == expected[label], "\(label)")
            // Explaining a rejection never changes it.
            #expect(throws: TaskLensError.validationFailed(.invalidPresentation), "\(label)") { try PowerPointPackage.validate(data) }
        }
        #expect(PowerPointPackage.rejection(of: TestZip.powerPoint(slides: 3)) == nil)
        #expect(PowerPointPackage.rejection(of: Data()) == .malformed)
    }
}

private struct Failing: PresentationLoading {
    let error: any Error
    func loadPresentation() async throws -> PresentationDocument { throw error }
}

@testable import DocumentsFeature
import Testing

@Suite("PDF reader page changes")
struct PDFPageChangeFilterTests {
    @Test func aNewViewReportingTheFirstPageDoesNotOverrideTheSavedPage() {
        var filter = PDFPageChangeFilter()
        // The reader opens on saved page 2 (zero-based 1).
        filter.requested(1)
        // PDFKit reports its own first page while it lays out: show page 2 again, save nothing.
        #expect(filter.pageChanged(to: 0, isOnScreen: true, isUserScrolling: false) == .restore(1))
        // It reaches page 2: nothing to save, the reader is already there.
        #expect(filter.pageChanged(to: 1, isOnScreen: true, isUserScrolling: false) == .ignore)
        #expect(filter.pending == nil)
    }

    @Test func anOffScreenViewIsIgnored() {
        var filter = PDFPageChangeFilter()
        #expect(filter.pageChanged(to: 0, isOnScreen: false, isUserScrolling: false) == .ignore)
        filter.requested(2)
        #expect(filter.pageChanged(to: 0, isOnScreen: false, isUserScrolling: false) == .ignore)
        #expect(filter.pending == 2, "Still waiting for the requested page")
    }

    @Test func theUsersScrollingAlwaysCounts() {
        var filter = PDFPageChangeFilter()
        filter.requested(3)
        #expect(filter.pageChanged(to: 5, isOnScreen: true, isUserScrolling: true) == .report(5))
        #expect(filter.pending == nil)
        #expect(filter.pageChanged(to: 6, isOnScreen: true, isUserScrolling: true) == .report(6))
    }

    @Test func changesAfterSettlingAreReported() {
        var filter = PDFPageChangeFilter()
        filter.requested(1)
        filter.settled()
        // VoiceOver scrolling or a search match: no drag, but on screen and nothing pending.
        #expect(filter.pageChanged(to: 4, isOnScreen: true, isUserScrolling: false) == .report(4))
    }
}

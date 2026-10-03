import Foundation
import Testing
@testable import TLDomain
import TLFoundation

@Suite("Presentation models")
struct PresentationDocumentTests {
    private func document(_ kind: FileKind, title: String = "Deck") -> Document {
        Document(
            title: title,
            file: FileReference(relativePath: "Documents/x", contentType: "public.data", kind: kind),
            pageCount: 3,
            lastReadPage: 2,
            createdAt: Fixtures.date
        )
    }

    @Test(arguments: [1, 10, 50, 100])
    func pdfMakesOneSlidePerPage(pageCount: Int) throws {
        let pdf = document(.pdf)
        let presentation = try PresentationDocument.pdf(pdf, pageCount: pageCount, createdAt: Fixtures.date)
        #expect(presentation.sourceType == .pdf)
        #expect(presentation.documentID == pdf.id)
        #expect(presentation.title == "Deck")
        #expect(presentation.slideCount == pageCount)
        #expect(presentation.slides.map(\.index) == Array(0..<pageCount))
        #expect(presentation.slides.last?.source == .pdfPage(pdf.id, pageIndex: pageCount - 1))
        #expect(presentation.slides.last?.displayNumber == pageCount)
    }

    @Test func pdfRejectsOtherKindsAndEmptyFiles() {
        #expect(throws: TaskLensError.unsupportedContent(type: "image")) {
            try PresentationDocument.pdf(document(.image), pageCount: 3, createdAt: Fixtures.date)
        }
        #expect(throws: TaskLensError.validationFailed(.emptyContent)) {
            try PresentationDocument.pdf(document(.pdf), pageCount: 0, createdAt: Fixtures.date)
        }
    }

    @Test func imagesKeepTheirOrder() throws {
        let images = (0..<4).map { document(.image, title: "Photo \($0)") }
        let presentation = try PresentationDocument.images(images, title: "Trip", createdAt: Fixtures.date)
        #expect(presentation.sourceType == .image)
        #expect(presentation.documentID == images[0].id)
        #expect(presentation.slides.map(\.source.documentID) == images.map(\.id))
        #expect(presentation.slide(at: 3)?.source == .image(images[3].id))
        #expect(presentation.slide(at: 4) == nil)
        #expect(presentation.slide(at: -1) == nil)
    }

    @Test func imagesRejectEmptyAndMixedSets() {
        #expect(throws: TaskLensError.validationFailed(.emptyContent)) {
            try PresentationDocument.images([], title: "Empty", createdAt: Fixtures.date)
        }
        #expect(throws: TaskLensError.unsupportedContent(type: "pdf")) {
            try PresentationDocument.images([document(.image), document(.pdf)], title: "Mixed", createdAt: Fixtures.date)
        }
    }

    @Test func onlyPDFAndImagesAreSupportedToday() {
        #expect(PresentationSourceType.allCases.filter(\.isSupported) == [.pdf, .image])
    }

    @Test func buildingAPresentationLeavesTheReadingPageAlone() throws {
        let pdf = document(.pdf)
        _ = try PresentationDocument.pdf(pdf, pageCount: 3, createdAt: Fixtures.date)
        #expect(pdf.lastReadPage == 2)
    }

    @Test func roundTripsThroughCoding() throws {
        let presentation = try PresentationDocument.pdf(document(.pdf), pageCount: 5, createdAt: Fixtures.date)
        #expect(try Fixtures.roundTrip(presentation) == presentation)
        var state = PresentationState()
        state.beginLoading()
        state.finishLoading(slideCount: 5, startAt: 2)
        state.start()
        #expect(try Fixtures.roundTrip(state) == state)
        state.fail(.unreadable)
        #expect(try Fixtures.roundTrip(state) == state)
    }
}

@Suite("Presentation state transitions")
struct PresentationStateTests {
    private func loaded(_ count: Int, at start: Int = 0) -> PresentationState {
        var state = PresentationState()
        state.beginLoading()
        state.finishLoading(slideCount: count, startAt: start)
        return state
    }

    @Test func startsIdleWithNoSlides() {
        let state = PresentationState()
        #expect(state.phase == .idle)
        #expect(state.slideCount == 0)
        #expect(state.displaySlideNumber == 0)
        #expect(!state.hasSlides)
    }

    @Test func loadingReachesReadyAtTheFirstSlide() {
        var state = PresentationState()
        #expect(state.beginLoading())
        #expect(state.phase == .loading)
        #expect(!state.beginLoading())
        #expect(state.finishLoading(slideCount: 48))
        #expect(state.phase == .ready)
        #expect(state.currentSlide == 0)
        #expect(state.displaySlideNumber == 1)
        #expect(state.slideCount == 48)
    }

    @Test func finishLoadingNeedsLoadingAndSlides() {
        var state = PresentationState()
        #expect(!state.finishLoading(slideCount: 3))
        #expect(state.phase == .idle)
        state.beginLoading()
        state.finishLoading(slideCount: 0)
        #expect(state.phase == .error(.empty))
        #expect(!state.next())
    }

    @Test func startSlideIsClamped() {
        #expect(loaded(10, at: 99).currentSlide == 9)
        #expect(loaded(10, at: -5).currentSlide == 0)
    }

    @Test func playPauseStop() {
        var state = loaded(5, at: 2)
        #expect(!state.pause())
        #expect(state.start())
        #expect(state.phase == .playing)
        #expect(!state.start())
        #expect(state.pause())
        #expect(state.phase == .paused)
        #expect(state.start())
        #expect(state.stop())
        #expect(state.phase == .ready)
        #expect(state.currentSlide == 2)
        #expect(!state.stop())
    }

    @Test(arguments: [10, 50, 100])
    func playingThroughEverySlideCompletes(count: Int) {
        var state = loaded(count)
        state.start()
        for expected in 1..<count {
            #expect(state.next())
            #expect(state.currentSlide == expected)
        }
        #expect(state.isLastSlide)
        #expect(state.displaySlideNumber == count)
        #expect(state.next())
        #expect(state.phase == .completed)
        #expect(state.currentSlide == count - 1)
        #expect(!state.next())
    }

    @Test func nextOnLastSlideWhenNotPlayingDoesNothing() {
        var state = loaded(3, at: 2)
        #expect(!state.next())
        #expect(state.phase == .ready)
    }

    @Test func previousStopsAtTheFirstSlide() {
        var state = loaded(3, at: 1)
        #expect(state.previous())
        #expect(state.isFirstSlide)
        #expect(!state.previous())
    }

    @Test func goToClampsAndIgnoresTheSameSlide() {
        var state = loaded(12)
        #expect(state.goTo(slide: 11))
        #expect(state.displaySlideNumber == 12)
        #expect(!state.goTo(slide: 500))
        #expect(state.goTo(slide: -3))
        #expect(state.currentSlide == 0)
    }

    @Test func leavingCompletedPausesAndStartRestarts() {
        var state = loaded(3, at: 2)
        state.start()
        state.next()
        #expect(state.phase == .completed)
        #expect(state.previous())
        #expect(state.phase == .paused)
        state.start()
        state.goTo(slide: 2)
        state.next()
        #expect(state.start())
        #expect(state.phase == .playing)
        #expect(state.currentSlide == 0)
    }

    @Test func navigationNeedsSlides() {
        var state = PresentationState()
        #expect(!state.next())
        #expect(!state.previous())
        #expect(!state.goTo(slide: 1))
        #expect(!state.start())
    }

    @Test func failureStopsEverythingUntilReloaded() {
        var state = loaded(4, at: 1)
        state.start()
        state.fail(.unreadable)
        #expect(state.phase == .error(.unreadable))
        #expect(!state.next())
        #expect(!state.start())
        #expect(state.beginLoading())
        #expect(state.currentSlide == 0)
    }
}

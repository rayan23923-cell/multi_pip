import Foundation
import Testing
import TLCoreServices

/// Builds the presentation parts of a deck: `slides` are the part names in
/// `sldIdLst` order, and each gets a relationship ID that does not follow that order.
private enum DeckXML {
    static let relationshipBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    static func presentation(order: [(id: Int, rID: String)], size: (Int, Int)? = (12_192_000, 6_858_000)) -> String {
        let ids = order.map { #"<p:sldId id="\#($0.id)" r:id="\#($0.rID)"/>"# }.joined()
        let sizeXML = size.map { #"<p:sldSz cx="\#($0.0)" cy="\#($0.1)"/>"# } ?? ""
        return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
            + #"<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="\#(relationshipBase)">"#
            + #"<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rIdMaster"/></p:sldMasterIdLst>"#
            + "<p:sldIdLst>\(ids)</p:sldIdLst>\(sizeXML)</p:presentation>"
    }

    static func relationships(_ items: [(id: String, type: String, target: String, external: Bool)]) -> String {
        let body = items.map {
            #"<Relationship Id="\#($0.id)" Type="\#(relationshipBase)/\#($0.type)" Target="\#($0.target)""#
                + ($0.external ? #" TargetMode="External""# : "") + "/>"
        }.joined()
        return #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(body)</Relationships>"#
    }

    static func slide(hidden: Bool = false) -> String {
        #"<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"\#(hidden ? #" show="0""# : "")><p:cSld/></p:sld>"#
    }

    /// Slide parts named 1...n, listed in the presentation as `order` (indices into those parts).
    static func deck(parts: Int, order: [Int], hidden: Set<Int> = [], size: (Int, Int)? = (12_192_000, 6_858_000),
                     extra: [TestZip.Entry] = [], deflated: Bool = false) -> Data {
        let presentationOrder = order.enumerated().map { (id: 256 + $0.offset, rID: "rId\(100 - $0.element)") }
        let rels = (1...parts).map { (id: "rId\(100 - $0)", type: "slide", target: "slides/slide\($0).xml", external: false) }
        return TestZip.make([
            TestZip.Entry("[Content_Types].xml"),
            TestZip.Entry("ppt/presentation.xml", presentation(order: presentationOrder, size: size), deflated: deflated),
            TestZip.Entry("ppt/_rels/presentation.xml.rels", relationships(rels), deflated: deflated),
        ] + (1...parts).map { TestZip.Entry("ppt/slides/slide\($0).xml", slide(hidden: hidden.contains($0)), deflated: deflated) }
            + extra)
    }
}

@Suite("PowerPoint deck structure")
struct PowerPointDeckTests {
    @Test func slidesFollowThePresentationOrderNotPartNames() throws {
        let deck = try PowerPointDeck.read(DeckXML.deck(parts: 5, order: [3, 1, 5, 2, 4]))
        #expect(deck.slides.map(\.part) == [3, 1, 5, 2, 4].map { "ppt/slides/slide\($0).xml" })
        #expect(deck.slides.map(\.position) == [1, 2, 3, 4, 5])
        #expect(deck.slides.map(\.slideID) == [256, 257, 258, 259, 260])
        #expect(deck.visibleSlides.count == 5)
    }

    @Test func unusedSlidePartsAreNotSlides() throws {
        let deck = try PowerPointDeck.read(DeckXML.deck(parts: 4, order: [2, 4]))
        #expect(deck.slides.map(\.part) == ["ppt/slides/slide2.xml", "ppt/slides/slide4.xml"])
    }

    @Test func compressedPartsAreRead() throws {
        let deck = try PowerPointDeck.read(DeckXML.deck(parts: 3, order: [2, 3, 1], hidden: [3], deflated: true))
        #expect(deck.slides.map(\.part) == [2, 3, 1].map { "ppt/slides/slide\($0).xml" })
        #expect(deck.slides.map(\.isHidden) == [false, true, false])
    }

    @Test func hiddenSlidesAreMarked() throws {
        let deck = try PowerPointDeck.read(DeckXML.deck(parts: 3, order: [1, 2, 3], hidden: [2]))
        #expect(deck.slides.map(\.isHidden) == [false, true, false])
        #expect(deck.visibleSlides.map(\.position) == [1, 3])
    }

    @Test(arguments: [
        ((12_192_000, 6_858_000), 16.0 / 9.0),
        ((9_144_000, 6_858_000), 4.0 / 3.0),
        ((6_858_000, 6_858_000), 1.0),
        ((6_858_000, 9_144_000), 3.0 / 4.0),
    ])
    func slideSizeComesFromTheDeck(size: (Int, Int), ratio: Double) throws {
        let deck = try PowerPointDeck.read(DeckXML.deck(parts: 1, order: [1], size: size))
        #expect(deck.slideWidthEMU == Int64(size.0))
        #expect(deck.slideHeightEMU == Int64(size.1))
        #expect(abs(deck.aspectRatio - ratio) < 0.0001)
    }

    @Test func missingSlideSizeIsFourByThree() throws {
        let deck = try PowerPointDeck.read(DeckXML.deck(parts: 1, order: [1], size: nil))
        #expect(deck.slideWidthEMU == 9_144_000)
        #expect(deck.slideHeightEMU == 6_858_000)
    }

    @Test func targetsResolveRelativeAndAbsolute() throws {
        let rels = DeckXML.relationships([
            (id: "rId1", type: "slide", target: "/ppt/slides/slide2.xml", external: false),
            (id: "rId2", type: "slide", target: "./slides/../slides/slide1.xml", external: false),
        ])
        let data = TestZip.make([
            TestZip.Entry("[Content_Types].xml"),
            TestZip.Entry("ppt/presentation.xml", DeckXML.presentation(order: [(256, "rId1"), (257, "rId2")])),
            TestZip.Entry("ppt/_rels/presentation.xml.rels", rels),
            TestZip.Entry("ppt/slides/slide1.xml", DeckXML.slide()),
            TestZip.Entry("ppt/slides/slide2.xml", DeckXML.slide()),
        ])
        #expect(try PowerPointDeck.read(data).slides.map(\.part) == ["ppt/slides/slide2.xml", "ppt/slides/slide1.xml"])
    }

    @Test func externalLinksAreCountedNotRequired() throws {
        let slideRels = DeckXML.relationships([
            (id: "rId1", type: "image", target: "https://example.invalid/a.png", external: true),
            (id: "rId2", type: "hyperlink", target: "https://example.invalid", external: true),
            (id: "rId3", type: "image", target: "../media/image1.png", external: false),
        ])
        let deck = try PowerPointDeck.read(DeckXML.deck(parts: 1, order: [1], extra: [
            TestZip.Entry("ppt/slides/_rels/slide1.xml.rels", slideRels),
            TestZip.Entry("ppt/media/image1.png", "png"),
        ]))
        #expect(deck.externalResourceCount == 1)
        #expect(deck.externalHyperlinkCount == 1)
    }

    @Test func speakerNotesArePresentNotRead() throws {
        #expect(try PowerPointDeck.read(DeckXML.deck(parts: 1, order: [1])).hasSpeakerNotes == false)
        let withNotes = DeckXML.deck(parts: 1, order: [1], extra: [TestZip.Entry("ppt/notesSlides/notesSlide1.xml", "not xml at all")])
        #expect(try PowerPointDeck.read(withNotes).hasSpeakerNotes)
    }

    // MARK: Failures

    @Test func missingSlidePartIsAMissingResource() {
        let parts = TestZip.make([
            TestZip.Entry("[Content_Types].xml"),
            TestZip.Entry("ppt/presentation.xml", DeckXML.presentation(order: [(256, "rId1"), (257, "rId2")])),
            TestZip.Entry("ppt/_rels/presentation.xml.rels", DeckXML.relationships([
                (id: "rId1", type: "slide", target: "slides/slide1.xml", external: false),
                (id: "rId2", type: "slide", target: "slides/slide2.xml", external: false),
            ])),
            TestZip.Entry("ppt/slides/slide1.xml", DeckXML.slide()),
        ])
        #expect(throws: PowerPointRenderError.resourceMissing(part: "ppt/slides/slide2.xml")) { try PowerPointDeck.read(parts) }
    }

    @Test func missingPictureIsAMissingResource() {
        let slideRels = DeckXML.relationships([(id: "rId3", type: "image", target: "../media/gone.png", external: false)])
        let data = DeckXML.deck(parts: 1, order: [1], extra: [TestZip.Entry("ppt/slides/_rels/slide1.xml.rels", slideRels)])
        #expect(throws: PowerPointRenderError.resourceMissing(part: "ppt/media/gone.png")) { try PowerPointDeck.read(data) }
    }

    static let brokenDecks: [(String, Data)] = [
        ("not a package", Data("hello".utf8)),
        ("macro project", DeckXML.deck(parts: 1, order: [1], extra: [TestZip.Entry("ppt/vbaProject.bin")])),
        ("presentation is not XML", TestZip.make([
            TestZip.Entry("[Content_Types].xml"), TestZip.Entry("ppt/presentation.xml", "<p:presentation><unclosed"),
        ])),
        ("entity declaration", TestZip.make([
            TestZip.Entry("[Content_Types].xml"),
            TestZip.Entry("ppt/presentation.xml", #"<?xml version="1.0"?><!DOCTYPE p [<!ENTITY x SYSTEM "file:///etc/hosts">]><p:presentation>&x;</p:presentation>"#),
        ])),
        ("slide ID with unknown relationship", TestZip.make([
            TestZip.Entry("[Content_Types].xml"),
            TestZip.Entry("ppt/presentation.xml", DeckXML.presentation(order: [(256, "rId9")])),
            TestZip.Entry("ppt/_rels/presentation.xml.rels", DeckXML.relationships([])),
        ])),
        ("same slide listed twice", TestZip.make([
            TestZip.Entry("[Content_Types].xml"),
            TestZip.Entry("ppt/presentation.xml", DeckXML.presentation(order: [(256, "rId1"), (257, "rId2")])),
            TestZip.Entry("ppt/_rels/presentation.xml.rels", DeckXML.relationships([
                (id: "rId1", type: "slide", target: "slides/slide1.xml", external: false),
                (id: "rId2", type: "slide", target: "slides/slide1.xml", external: false),
            ])),
            TestZip.Entry("ppt/slides/slide1.xml", DeckXML.slide()),
        ])),
        ("slide that is not a slide", TestZip.make([
            TestZip.Entry("[Content_Types].xml"),
            TestZip.Entry("ppt/presentation.xml", DeckXML.presentation(order: [(256, "rId1")])),
            TestZip.Entry("ppt/_rels/presentation.xml.rels", DeckXML.relationships([
                (id: "rId1", type: "slide", target: "slides/slide1.xml", external: false),
            ])),
            TestZip.Entry("ppt/slides/slide1.xml", "<w:document/>"),
        ])),
        ("target leaving the package", TestZip.make([
            TestZip.Entry("[Content_Types].xml"),
            TestZip.Entry("ppt/presentation.xml", DeckXML.presentation(order: [(256, "rId1")])),
            TestZip.Entry("ppt/_rels/presentation.xml.rels", DeckXML.relationships([
                (id: "rId1", type: "slide", target: "../../../etc/slide1.xml", external: false),
            ])),
        ])),
        ("zero slide size", DeckXML.deck(parts: 1, order: [1], size: (0, 6_858_000))),
        ("part listed twice in the ZIP", DeckXML.deck(parts: 1, order: [1], extra: [TestZip.Entry("ppt/slides/slide1.xml")])),
        ("cut short", DeckXML.deck(parts: 2, order: [1, 2]).dropLast(40)),
    ]

    @Test(arguments: brokenDecks.indices)
    func brokenDeckIsInvalid(index: Int) {
        let (label, data) = Self.brokenDecks[index]
        #expect(throws: PowerPointRenderError.invalidPresentation, "\(label)") { try PowerPointDeck.read(data) }
    }

    @Test func unreadableFileIsInvalid() {
        #expect(throws: PowerPointRenderError.invalidPresentation) {
            try PowerPointDeck.read(contentsOf: URL(fileURLWithPath: "/nonexistent/deck.pptx"))
        }
    }

    @Test func deckWithNoSlidesHasNoSlides() throws {
        let data = TestZip.make([
            TestZip.Entry("[Content_Types].xml"),
            TestZip.Entry("ppt/presentation.xml", DeckXML.presentation(order: [])),
        ])
        #expect(try PowerPointDeck.read(data).slides.isEmpty)
    }
}

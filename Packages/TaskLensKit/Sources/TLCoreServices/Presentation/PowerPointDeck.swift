import Compression
import Foundation

/// Why a PowerPoint file could not be turned into slide images.
///
/// Thrown by `PowerPointDeck.read` and by the WebKit renderer. It carries no
/// user-facing text and no file content: `part` is a path inside the package.
public enum PowerPointRenderError: Error, Equatable, Sendable {
    /// Not a package TaskLens accepts, or its presentation parts are broken.
    case invalidPresentation
    /// A well-formed package that WebKit refuses to open (for example decks
    /// with speaker notes, OfficeImport error 912).
    case unsupportedContent
    /// A slide, or a picture, chart or layout a slide uses, is not in the package.
    case resourceMissing(part: String)
    /// WebKit opened the deck but the result can't be trusted.
    case renderingFailed(RenderingFailure)
    /// The web view could not be set up, or its process ended.
    case webViewFailed
    case timeout
    case cancelled

    public enum RenderingFailure: Equatable, Sendable {
        case slideCountMismatch(expected: Int, rendered: Int)
        case slideSizeMismatch
        case noVisibleSlides
        case snapshotFailed(slide: Int)
        case writeFailed
    }
}

/// What `ppt/presentation.xml` and its relationships say about a deck: the
/// slides in presentation order, their size, and which are hidden.
///
/// Order comes only from `<p:sldIdLst>` through the presentation's
/// relationships. Part names, relationship IDs and dates are never sorted.
/// Parts are inflated with the Compression framework and parsed with
/// `XMLParser`, which does not load external entities; any DTD is refused.
public struct PowerPointDeck: Equatable, Sendable {
    public struct Slide: Equatable, Sendable {
        /// 1-based position in the presentation, hidden slides included.
        public var position: Int
        /// The `id` attribute of `<p:sldId>`, unique and stable within the deck.
        public var slideID: UInt32
        /// Package path, for example `ppt/slides/slide3.xml`.
        public var part: String
        /// `show="0"` on the slide: skipped when presenting.
        public var isHidden: Bool
    }

    public var slides: [Slide]
    /// Slide size in EMU (914,400 per inch). 4:3 when the deck doesn't say.
    public var slideWidthEMU: Int64
    public var slideHeightEMU: Int64
    /// The package holds speaker notes. Their text is never read.
    public var hasSpeakerNotes: Bool
    /// Links from slides to outside the file: web links, and pictures or media
    /// that would be fetched. The renderer blocks all of them.
    public var externalHyperlinkCount: Int
    public var externalResourceCount: Int

    public var visibleSlides: [Slide] { slides.filter { !$0.isHidden } }
    public var aspectRatio: Double { Double(slideWidthEMU) / Double(slideHeightEMU) }

    static let defaultWidthEMU: Int64 = 9_144_000
    static let defaultHeightEMU: Int64 = 6_858_000
    /// No presentation part of a real deck comes near this.
    static let maximumPartSize: Int64 = 16 * 1024 * 1024
    /// Relationship types a slide needs to look right. A missing target is `resourceMissing`.
    static let requiredRelationshipTypes: Set<String> = [
        "slideLayout", "image", "chart", "diagramData", "diagramLayout",
        "diagramQuickStyle", "diagramColors", "diagramDrawing",
    ]
    static let externalResourceTypes: Set<String> = ["image", "media", "video", "audio", "oleObject", "package"]

    public static func read(contentsOf url: URL) throws -> PowerPointDeck {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw PowerPointRenderError.invalidPresentation }
        return try read(data)
    }

    public static func read(_ data: Data) throws -> PowerPointDeck {
        // The same check as import (A9.1): structure, size limits, no macros.
        guard (try? PowerPointPackage.validate(data)) != nil else { throw PowerPointRenderError.invalidPresentation }
        return try data.withUnsafeBytes { bytes in
            guard let entries = PowerPointPackage.directory(bytes) else { throw PowerPointRenderError.invalidPresentation }
            return try Reader(bytes: bytes, entries: entries).deck()
        }
    }

    private struct Reader {
        let bytes: UnsafeRawBufferPointer
        let entries: [String: PowerPointPackage.Entry]

        init(bytes: UnsafeRawBufferPointer, entries: [PowerPointPackage.Entry]) throws {
            self.bytes = bytes
            // A name listed twice is ambiguous: there is no telling which copy WebKit reads.
            var byName: [String: PowerPointPackage.Entry] = [:]
            for entry in entries {
                guard byName.updateValue(entry, forKey: entry.name) == nil else { throw PowerPointRenderError.invalidPresentation }
            }
            self.entries = byName
        }

        func deck() throws -> PowerPointDeck {
            let presentation = try parse("ppt/presentation.xml")
            let relationships = try self.relationships(of: "ppt/presentation.xml")

            var width = PowerPointDeck.defaultWidthEMU, height = PowerPointDeck.defaultHeightEMU
            if let size = presentation.elements.first(where: { $0.name == "sldSz" }) {
                guard let cx = size.attributes["cx"].flatMap(Int64.init), let cy = size.attributes["cy"].flatMap(Int64.init),
                      cx > 0, cy > 0 else { throw PowerPointRenderError.invalidPresentation }
                width = cx
                height = cy
            }

            var slides: [Slide] = []
            var seenIDs = Set<UInt32>(), seenParts = Set<String>()
            var hyperlinks = 0, resources = 0
            for element in presentation.elements where element.name == "sldId" {
                guard let id = element.attributes["id"].flatMap(UInt32.init),
                      let rID = element.relationshipID,
                      let relationship = relationships[rID], relationship.type == "slide", !relationship.isExternal,
                      seenIDs.insert(id).inserted, seenParts.insert(relationship.target).inserted
                else { throw PowerPointRenderError.invalidPresentation }
                guard entries[relationship.target] != nil else {
                    throw PowerPointRenderError.resourceMissing(part: relationship.target)
                }
                let slide = try parse(relationship.target, rootOnly: true)
                guard slide.elements.first?.name == "sld" else { throw PowerPointRenderError.invalidPresentation }
                let show = slide.elements.first?.attributes["show"]
                for used in try self.relationships(of: relationship.target).values {
                    if used.isExternal {
                        if used.type == "hyperlink" { hyperlinks += 1 }
                        if PowerPointDeck.externalResourceTypes.contains(used.type) { resources += 1 }
                    } else if PowerPointDeck.requiredRelationshipTypes.contains(used.type), entries[used.target] == nil {
                        throw PowerPointRenderError.resourceMissing(part: used.target)
                    }
                }
                slides.append(Slide(position: slides.count + 1, slideID: id, part: relationship.target,
                                    isHidden: show == "0" || show == "false"))
            }

            return PowerPointDeck(
                slides: slides, slideWidthEMU: width, slideHeightEMU: height,
                hasSpeakerNotes: entries.keys.contains { $0.hasPrefix("ppt/notesSlides/") },
                externalHyperlinkCount: hyperlinks, externalResourceCount: resources
            )
        }

        // MARK: Relationships

        struct Relationship {
            /// The last path component of the relationship type URI, e.g. `slide` or `image`.
            var type: String
            /// Package path for internal targets, the raw target for external ones.
            var target: String
            var isExternal: Bool
        }

        func relationships(of part: String) throws -> [String: Relationship] {
            let folder = part.split(separator: "/").dropLast().joined(separator: "/")
            let name = part.split(separator: "/").last.map(String.init) ?? part
            let relsPart = (folder.isEmpty ? "" : folder + "/") + "_rels/" + name + ".rels"
            // A part with no relationships simply has no .rels file.
            guard entries[relsPart] != nil else { return [:] }
            var result: [String: Relationship] = [:]
            for element in try parse(relsPart).elements where element.name == "Relationship" {
                guard let id = element.attributes["Id"], let target = element.attributes["Target"],
                      let type = element.attributes["Type"]?.split(separator: "/").last.map(String.init)
                else { throw PowerPointRenderError.invalidPresentation }
                if element.attributes["TargetMode"] == "External" {
                    result[id] = Relationship(type: type, target: target, isExternal: true)
                } else {
                    guard let resolved = Self.resolve(target, from: folder) else { throw PowerPointRenderError.invalidPresentation }
                    result[id] = Relationship(type: type, target: resolved, isExternal: false)
                }
            }
            return result
        }

        /// A relationship target inside the package, relative to the source part's folder.
        static func resolve(_ target: String, from folder: String) -> String? {
            let decoded = target.removingPercentEncoding ?? target
            var path: [Substring] = decoded.hasPrefix("/") ? [] : folder.split(separator: "/")
            for component in decoded.split(separator: "/") {
                switch component {
                case ".": continue
                case "..":
                    guard !path.isEmpty else { return nil }
                    path.removeLast()
                default: path.append(component)
                }
            }
            return path.isEmpty ? nil : path.joined(separator: "/")
        }

        // MARK: Parts

        func parse(_ part: String, rootOnly: Bool = false) throws -> ParsedXML {
            let data = try contents(of: part)
            // OOXML never uses a DTD; one can only be there to expand entities.
            if data.range(of: Data("<!DOCTYPE".utf8)) != nil || data.range(of: Data("<!ENTITY".utf8)) != nil {
                throw PowerPointRenderError.invalidPresentation
            }
            let collector = ParsedXML(rootOnly: rootOnly)
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = collector
            guard parser.parse() || collector.stoppedEarly, !collector.elements.isEmpty else {
                throw PowerPointRenderError.invalidPresentation
            }
            return collector
        }

        func contents(of part: String) throws -> Data {
            guard let entry = entries[part] else { throw PowerPointRenderError.resourceMissing(part: part) }
            guard entry.uncompressedSize <= PowerPointDeck.maximumPartSize else { throw PowerPointRenderError.invalidPresentation }
            let local = entry.localHeaderOffset
            guard local + 30 <= bytes.count, PowerPointPackage.read32(bytes, local) == PowerPointPackage.localHeader
            else { throw PowerPointRenderError.invalidPresentation }
            let start = local + 30 + Int(PowerPointPackage.read16(bytes, local + 26)) + Int(PowerPointPackage.read16(bytes, local + 28))
            let compressedSize = Int(entry.compressedSize), size = Int(entry.uncompressedSize)
            guard start + compressedSize <= bytes.count else { throw PowerPointRenderError.invalidPresentation }
            let source = UnsafeRawBufferPointer(rebasing: bytes[start..<(start + compressedSize)])

            switch entry.method {
            case 0:
                guard compressedSize == size else { throw PowerPointRenderError.invalidPresentation }
                return Data(source)
            case 8:
                guard size > 0 else { return Data() }
                guard compressedSize > 0, let base = source.baseAddress else { throw PowerPointRenderError.invalidPresentation }
                var output = Data(count: size)
                // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), the ZIP method 8 format.
                let written = output.withUnsafeMutableBytes { destination in
                    compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, size,
                                              base.assumingMemoryBound(to: UInt8.self), compressedSize, nil, COMPRESSION_ZLIB)
                }
                guard written == size else { throw PowerPointRenderError.invalidPresentation }
                return output
            default:
                throw PowerPointRenderError.invalidPresentation
            }
        }
    }

    /// Elements in document order, names without their namespace prefix.
    private final class ParsedXML: NSObject, XMLParserDelegate {
        struct Element {
            var name: String
            var attributes: [String: String]
            /// `r:id`, whatever prefix the relationships namespace was given.
            var relationshipID: String? {
                attributes.first { $0.key.hasSuffix(":id") }?.value
            }
        }

        let rootOnly: Bool
        var elements: [Element] = []
        var stoppedEarly = false

        init(rootOnly: Bool) { self.rootOnly = rootOnly }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
            elements.append(Element(name: name, attributes: attributes))
            if rootOnly {
                stoppedEarly = true
                parser.abortParsing()
            }
        }
    }
}

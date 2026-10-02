import Foundation
import TLDomain
import TLFoundation

// Smart Search turns sessions into searchable knowledge, entirely on device.
//
// 1. The query is read for hints ("prices", "PDF", "links", "yesterday",
//    "study", in English or Arabic) and keywords.
// 2. Keyword search runs over notes, links, documents (with their text),
//    OCR text, clipboard items, session content and detected entities.
// 3. When the OS has an on-device sentence embedding for the language,
//    results are re-ranked by meaning and close matches without the exact
//    words are added. Nothing is sent anywhere; without embeddings, keyword
//    search works alone.

/// What a search result is.
public enum SearchResultKind: String, Sendable, CaseIterable, Codable {
    case workspace
    case session
    case item
    case note
    case document
    case clipboard
}

/// Kinds of content the query asked for ("links", "PDF", "prices").
public enum SearchFilter: String, Sendable, Hashable, CaseIterable {
    case link
    case note
    case document
    case pdf
    case image
    case text
    case clipboard
    case price
    case phone
    case email
    case date
    case address
    case code
}

/// The query, read for hints and keywords.
public struct ParsedSearchQuery: Sendable, Equatable {
    public var keywords: [String]
    public var filters: Set<SearchFilter>
    public var dateRange: DateInterval?
    /// "study" in "PDF for study": matches workspace and session kinds.
    public var kindHint: String?

    public var hasHints: Bool { !filters.isEmpty || dateRange != nil || kindHint != nil }

    public init(keywords: [String] = [], filters: Set<SearchFilter> = [], dateRange: DateInterval? = nil, kindHint: String? = nil) {
        self.keywords = keywords
        self.filters = filters
        self.dateRange = dateRange
        self.kindHint = kindHint
    }
}

public enum SearchQueryParser {
    /// Hint words, English and Arabic (normalized: no "ال", ة→ه, أ→ا).
    static let filterWords: [(SearchFilter, [String])] = [
        (.link, ["link", "links", "url", "urls", "website", "websites", "رابط", "روابط", "موقع", "مواقع"]),
        (.note, ["note", "notes", "ملاحظه", "ملاحظات"]),
        (.pdf, ["pdf"]),
        (.document, ["document", "documents", "file", "files", "مستند", "مستندات", "ملف", "ملفات"]),
        (.image, ["image", "images", "photo", "photos", "screenshot", "screenshots", "صوره", "صور", "لقطه"]),
        (.text, ["text", "texts", "نص", "نصوص"]),
        (.clipboard, ["clipboard", "copied", "حافظه", "نسخت"]),
        (.price, ["price", "prices", "cost", "costs", "money", "سعر", "اسعار", "ثمن", "مبلغ", "مبالغ"]),
        (.phone, ["phone", "phones", "number", "numbers", "call", "هاتف", "رقم", "ارقام"]),
        (.email, ["email", "emails", "mail", "بريد", "ايميل"]),
        (.date, ["date", "dates", "meeting", "meetings", "appointment", "موعد", "مواعيد", "اجتماع", "تاريخ"]),
        (.address, ["address", "addresses", "location", "عنوان", "عناوين"]),
        (.code, ["code", "snippet", "كود", "برمجه"]),
    ]

    /// Words that only carry grammar ("that I saw", "about", "the").
    static let stopWords: Set<String> = [
        "the", "a", "an", "of", "for", "about", "that", "which", "i", "my", "me", "in", "on", "to", "from", "with",
        "saw", "seen", "viewed", "saved", "found", "show", "find", "all",
        "تي", "ذي", "الذي", "التي", "الذين", "عن", "في", "من", "الى", "على", "مع", "خاص", "الخاص", "الخاصه", "خاصه",
        "شاهدتها", "شاهدته", "شفتها", "حفظتها", "حفظته", "رايتها", "اللي", "كل", "اعرض", "ابحث",
    ]

    static let kindWords: [(String, [String])] = [
        ("study", ["study", "school", "university", "exam", "دراسه", "دراسي", "جامعه", "امتحان", "مدرسه"]),
        ("research", ["research", "بحث", "ابحاث"]),
        ("work", ["work", "job", "عمل", "شغل"]),
        ("shopping", ["shopping", "shop", "buy", "تسوق", "شراء"]),
        ("developer", ["developer", "programming", "dev", "تطوير", "مبرمج"]),
    ]

    public static func parse(_ query: String, now: Date, calendar: Calendar = .current) -> ParsedSearchQuery {
        var keywords: [String] = []
        var filters: Set<SearchFilter> = []
        var kindHint: String?
        var dateRange: DateInterval?

        let tokens = SearchText.tokens(query)
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            if let range = readDateRange(token, next: next, now: now, calendar: calendar) {
                dateRange = range.interval
                index += range.consumed
                continue
            }
            if let filter = filterWords.first(where: { $0.1.contains(token) })?.0 {
                filters.insert(filter)
            } else if let kind = kindWords.first(where: { $0.1.contains(token) })?.0 {
                kindHint = kind
            } else if !stopWords.contains(token) {
                keywords.append(token)
            }
            index += 1
        }
        // "PDF" is a document filter too.
        if filters.contains(.pdf) { filters.insert(.document) }
        return ParsedSearchQuery(keywords: keywords, filters: filters, dateRange: dateRange, kindHint: kindHint)
    }

    static func readDateRange(_ token: String, next: String?, now: Date, calendar: Calendar) -> (interval: DateInterval, consumed: Int)? {
        let today = calendar.startOfDay(for: now)
        func days(_ start: Int, _ length: Int) -> DateInterval? {
            guard let from = calendar.date(byAdding: .day, value: start, to: today),
                  let to = calendar.date(byAdding: .day, value: length, to: from) else { return nil }
            return DateInterval(start: from, end: to)
        }
        let isLast = ["last", "past", "ماضي", "ماضيه", "سابق"].contains(next ?? "")
        switch token {
        case "today", "يوم":
            return days(0, 1).map { (interval: $0, consumed: 1) }
        case "yesterday", "امس", "البارحه", "بارحه":
            return days(-1, 1).map { (interval: $0, consumed: 1) }
        case "week", "اسبوع":
            return days(-7, 8).map { (interval: $0, consumed: isLast ? 2 : 1) }
        case "month", "شهر":
            return days(-30, 31).map { (interval: $0, consumed: isLast ? 2 : 1) }
        case "last", "past":
            if next == "week" { return days(-7, 8).map { (interval: $0, consumed: 2) } }
            if next == "month" { return days(-30, 31).map { (interval: $0, consumed: 2) } }
            return nil
        default:
            return nil
        }
    }
}

/// Matching helpers: Arabic and English, case- and diacritic-insensitive.
public enum SearchText {
    /// Lowercased, no diacritics or tatweel, أإآ→ا, ة→ه, ى→ي, Arabic-Indic digits → ASCII.
    public static func normalize(_ text: String) -> String {
        var result = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let replacements: [(String, String)] = [("أ", "ا"), ("إ", "ا"), ("آ", "ا"), ("ة", "ه"), ("ى", "ي"), ("ـ", "")]
        for (from, to) in replacements { result = result.replacingOccurrences(of: from, with: to) }
        let digits = Array("٠١٢٣٤٥٦٧٨٩")
        result = String(result.map { character in
            if let value = digits.firstIndex(of: character) { return Character(String(value)) }
            return character
        })
        return result
    }

    /// Words, normalized, with Arabic "ال"/"بال"/"وال" prefixes removed.
    public static func tokens(_ text: String) -> [String] {
        normalize(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map(stripArabicPrefix)
    }

    static func stripArabicPrefix(_ word: String) -> String {
        for prefix in ["وال", "بال", "فال", "كال", "لل", "ال"] where word.hasPrefix(prefix) && word.count > prefix.count + 2 {
            return String(word.dropFirst(prefix.count))
        }
        return word
    }
}

/// One searchable thing, flattened from any store.
public struct SearchDocument: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: SearchResultKind
    public var targetID: UUID
    public var title: String
    public var body: String
    public var filters: Set<SearchFilter>
    public var date: Date
    public var kinds: Set<String>
    public var workspaceID: WorkspaceID?
    public var sessionID: SessionID?
    /// For documents and files: which viewer opens it.
    public var fileKind: FileKind?
    /// For links: the page.
    public var url: URL?

    /// Normalized words of title + body, for keyword matching.
    var titleTokens: Set<String> = []
    var bodyText: String = ""

    public init(
        id: String, kind: SearchResultKind, targetID: UUID, title: String, body: String,
        filters: Set<SearchFilter>, date: Date, kinds: Set<String> = [],
        workspaceID: WorkspaceID? = nil, sessionID: SessionID? = nil,
        fileKind: FileKind? = nil, url: URL? = nil
    ) {
        self.id = id
        self.kind = kind
        self.targetID = targetID
        self.title = title
        self.body = body
        self.filters = filters
        self.date = date
        self.kinds = kinds
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.fileKind = fileKind
        self.url = url
        self.titleTokens = Set(SearchText.tokens(title))
        self.bodyText = " " + SearchText.tokens(title + " " + body).joined(separator: " ") + " "
    }
}

public struct SearchHit: Sendable, Equatable, Identifiable {
    public enum Match: String, Sendable, Equatable {
        /// The words were found.
        case keyword
        /// Close in meaning, found by on-device embeddings.
        case meaning
        /// Only the query's hints matched (for example "prices yesterday").
        case filter
    }

    public var document: SearchDocument
    public var score: Double
    public var match: Match
    /// A short piece of the text around the first keyword.
    public var snippet: String

    public var id: String { document.id }
}

/// Meaning-based similarity, on device. 0 = same meaning, 2 = opposite.
public protocol SemanticRanking: Sendable {
    /// False when the OS has no embedding for this text's language.
    func isAvailable(for text: String) -> Bool
    func distance(between query: String, and text: String) -> Double?
}

/// Search over everything TaskLens keeps.
public struct SmartSearchService: Sendable {
    public static let defaultLimit = 40
    /// Embedding distance under which a result counts as close in meaning.
    public static let meaningThreshold = 0.85

    private let workspaces: any Repository<Workspace>
    private let sessions: any Repository<Session>
    private let contextItems: any Repository<ContextItem>
    private let notes: any Repository<Note>
    private let documents: any Repository<Document>
    private let clipboardItems: any Repository<ClipboardItem>
    private let semantic: (any SemanticRanking)?
    private let clock: any DateProviding

    public init(
        workspaces: any Repository<Workspace>,
        sessions: any Repository<Session>,
        contextItems: any Repository<ContextItem>,
        notes: any Repository<Note>,
        documents: any Repository<Document>,
        clipboardItems: any Repository<ClipboardItem>,
        semantic: (any SemanticRanking)? = nil,
        clock: any DateProviding = SystemDateProvider()
    ) {
        self.workspaces = workspaces
        self.sessions = sessions
        self.contextItems = contextItems
        self.notes = notes
        self.documents = documents
        self.clipboardItems = clipboardItems
        self.semantic = semantic
        self.clock = clock
    }

    public struct Response: Sendable, Equatable {
        public var hits: [SearchHit]
        public var query: ParsedSearchQuery
        /// True when meaning-based ranking was used for this query.
        public var usedMeaning: Bool

        public init(hits: [SearchHit] = [], query: ParsedSearchQuery = ParsedSearchQuery(), usedMeaning: Bool = false) {
            self.hits = hits
            self.query = query
            self.usedMeaning = usedMeaning
        }
    }

    public func search(_ text: String, limit: Int = SmartSearchService.defaultLimit) async throws -> Response {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Response() }
        let query = SearchQueryParser.parse(trimmed, now: clock.now())
        let corpus = try await index()
        let useMeaning = !query.keywords.isEmpty && (semantic?.isAvailable(for: query.keywords.joined(separator: " ")) ?? false)
        let hits = Self.rank(corpus, query: query, semantic: useMeaning ? semantic : nil)
        return Response(hits: Array(hits.prefix(limit)), query: query, usedMeaning: useMeaning)
    }

    /// Everything searchable, flattened.
    public func index() async throws -> [SearchDocument] {
        let workspaces = try await self.workspaces.fetchAll()
        let sessions = try await self.sessions.fetchAll()
        let workspaceKinds = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.kind.rawValue) })
        let sessionKinds = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.kind.rawValue) })
        func kinds(_ workspaceID: WorkspaceID?, _ sessionID: SessionID?) -> Set<String> {
            Set([workspaceID.flatMap { workspaceKinds[$0] }, sessionID.flatMap { sessionKinds[$0] }].compactMap { $0 })
        }

        var corpus: [SearchDocument] = []
        for workspace in workspaces where !workspace.isArchived {
            corpus.append(SearchDocument(
                id: "workspace-\(workspace.id.uuidString)", kind: .workspace, targetID: workspace.id.rawValue,
                title: workspace.name, body: "", filters: [], date: workspace.lastOpenedAt ?? workspace.createdAt,
                kinds: [workspace.kind.rawValue], workspaceID: workspace.id
            ))
        }
        for session in sessions {
            corpus.append(SearchDocument(
                id: "session-\(session.id.uuidString)", kind: .session, targetID: session.id.rawValue,
                title: session.title ?? "", body: "", filters: [], date: session.lastActivityAt,
                kinds: kinds(session.workspaceID, session.id), workspaceID: session.workspaceID, sessionID: session.id
            ))
        }
        for item in try await contextItems.fetchAll() {
            corpus.append(SearchDocument(
                id: "item-\(item.id.uuidString)", kind: .item, targetID: item.id.rawValue,
                title: Self.title(of: item.content), body: Self.body(of: item),
                filters: Self.filters(of: item.content, entities: item.entities, source: item.source),
                date: item.createdAt, kinds: kinds(item.workspaceID, item.sessionID),
                workspaceID: item.workspaceID, sessionID: item.sessionID,
                fileKind: Self.fileKind(of: item.content), url: Self.url(of: item.content)
            ))
        }
        for note in try await notes.fetchAll() where !note.isEmpty {
            corpus.append(SearchDocument(
                id: "note-\(note.id.uuidString)", kind: .note, targetID: note.id.rawValue,
                title: note.title, body: note.body,
                filters: Self.entityFilters(ContextEngine.analyze(text: note.title + "\n" + note.body).entities).union([.note, .text]),
                date: note.updatedAt, kinds: kinds(note.workspaceID, note.sessionID),
                workspaceID: note.workspaceID, sessionID: note.sessionID
            ))
        }
        for document in try await documents.fetchAll() {
            var filters: Set<SearchFilter> = [.document]
            if document.kind == .pdf { filters.insert(.pdf) }
            if document.kind == .image { filters.insert(.image) }
            corpus.append(SearchDocument(
                id: "document-\(document.id.uuidString)", kind: .document, targetID: document.id.rawValue,
                title: document.title, body: [document.file.originalFilename, DocumentService.searchText(of: document)].compactMap { $0 }.joined(separator: "\n"),
                filters: filters, date: document.lastOpenedAt ?? document.createdAt,
                kinds: kinds(document.workspaceID, document.sessionID),
                workspaceID: document.workspaceID, sessionID: document.sessionID,
                fileKind: document.kind
            ))
        }
        for clip in try await clipboardItems.fetchAll() {
            corpus.append(SearchDocument(
                id: "clipboard-\(clip.id.uuidString)", kind: .clipboard, targetID: clip.id.rawValue,
                title: Self.title(of: clip.content), body: Self.text(of: clip.content),
                filters: Self.filters(of: clip.content, entities: [], source: .clipboard).union([.clipboard]),
                date: clip.capturedAt, url: Self.url(of: clip.content)
            ))
        }
        return corpus
    }

    // MARK: Ranking

    static func rank(_ corpus: [SearchDocument], query: ParsedSearchQuery, semantic: (any SemanticRanking)?) -> [SearchHit] {
        var hits: [SearchHit] = []
        let phrase = query.keywords.joined(separator: " ")
        for document in corpus {
            guard passes(document, query: query) else { continue }
            var score = 0.0
            var matched = 0
            for keyword in query.keywords {
                if document.titleTokens.contains(keyword) {
                    score += 3; matched += 1
                } else if document.titleTokens.contains(where: { $0.hasPrefix(keyword) }) {
                    score += 2; matched += 1
                } else if document.bodyText.contains(" " + keyword) {
                    score += 1; matched += 1
                }
            }
            let allKeywords = matched == query.keywords.count
            var match: SearchHit.Match?
            if !query.keywords.isEmpty && allKeywords {
                match = .keyword
                if query.keywords.count > 1, document.bodyText.contains(" " + phrase) { score += 2 }
            } else if query.keywords.isEmpty && query.hasHints {
                match = .filter
                score = 1
            }
            if let semantic, !query.keywords.isEmpty, document.kind != .workspace {
                let text = String((document.title + "\n" + document.body).prefix(500))
                if let distance = semantic.distance(between: phrase, and: text) {
                    if match == .keyword {
                        score += max(0, 1.5 - distance)
                    } else if distance < meaningThreshold {
                        match = .meaning
                        score = max(0.5, 1.2 - distance)
                    }
                }
            }
            guard let match else { continue }
            // Filters asked for this kind: put it first.
            if !query.filters.isEmpty { score += 1 }
            hits.append(SearchHit(document: document, score: score, match: match, snippet: snippet(document, keywords: query.keywords)))
        }
        return hits.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.document.date > rhs.document.date
        }
    }

    static func passes(_ document: SearchDocument, query: ParsedSearchQuery) -> Bool {
        if !query.filters.isEmpty {
            // Content filters need content: workspaces and sessions only match by name.
            guard document.kind != .workspace, document.kind != .session else { return false }
            let wanted = query.filters.subtracting([.document]).isEmpty ? query.filters : query.filters.subtracting([.document])
            guard !wanted.isDisjoint(with: document.filters) else { return false }
        }
        if let range = query.dateRange, !range.contains(document.date) { return false }
        if let kind = query.kindHint, !document.kinds.contains(kind) {
            // "study" (or "دراسة") can also be a plain word in the title or text.
            let words = SearchQueryParser.kindWords.first { $0.0 == kind }?.1 ?? [kind]
            guard words.contains(where: { document.bodyText.contains(" " + $0 + " ") }) else { return false }
        }
        return true
    }

    static func snippet(_ document: SearchDocument, keywords: [String]) -> String {
        let body = document.body.replacingOccurrences(of: "\n", with: " ")
        guard !body.isEmpty else { return "" }
        let normalized = SearchText.normalize(body)
        for keyword in keywords {
            if let range = normalized.range(of: keyword) {
                let offset = normalized.distance(from: normalized.startIndex, to: range.lowerBound)
                let start = body.index(body.startIndex, offsetBy: max(0, min(offset, body.count) - 30))
                let end = body.index(start, offsetBy: min(120, body.distance(from: start, to: body.endIndex)))
                return (start > body.startIndex ? "…" : "") + String(body[start..<end]) + (end < body.endIndex ? "…" : "")
            }
        }
        return String(body.prefix(120))
    }

    // MARK: Flattening

    static func title(of content: ContextContent) -> String {
        switch content {
        case .text(let text): String(text.split(separator: "\n").first?.prefix(80) ?? "")
        case .url(let url): url.host() ?? url.absoluteString
        case .file(let file): file.originalFilename ?? ""
        }
    }

    static func text(of content: ContextContent) -> String {
        switch content {
        case .text(let text): text
        case .url(let url): url.absoluteString
        case .file(let file): file.originalFilename ?? ""
        }
    }

    static func fileKind(of content: ContextContent) -> FileKind? {
        if case .file(let file) = content { return file.kind }
        return nil
    }

    static func url(of content: ContextContent) -> URL? {
        if case .url(let url) = content { return url }
        return nil
    }

    static func body(of item: ContextItem) -> String {
        var parts = [text(of: item.content)]
        // OCR text and page titles saved with the item.
        for key in ["title", "ocrText", "pageTitle", "summary"] {
            if let value = item.metadata[key]?.stringValue { parts.append(value) }
        }
        parts += item.entities.compactMap(\.matchedText)
        return parts.joined(separator: "\n")
    }

    static func filters(of content: ContextContent, entities: [DetectedEntity], source: ContextSource) -> Set<SearchFilter> {
        var filters: Set<SearchFilter> = []
        switch content {
        case .text(let text):
            filters.insert(.text)
            let found = entities.isEmpty ? ContextEngine.analyze(text: String(text.prefix(5_000))).entities : entities
            filters.formUnion(entityFilters(found))
        case .url:
            filters.insert(.link)
        case .file(let file):
            filters.insert(.document)
            if file.kind == .pdf { filters.insert(.pdf) }
            if file.kind == .image { filters.insert(.image) }
        }
        if [.camera, .photoLibrary, .screenCapture].contains(source) { filters.insert(.image) }
        return filters
    }

    static func entityFilters(_ entities: [DetectedEntity]) -> Set<SearchFilter> {
        Set(entities.compactMap { entity -> SearchFilter? in
            switch entity.type {
            case .currencyAmount: .price
            case .phoneNumber: .phone
            case .email: .email
            case .url: .link
            case .date: .date
            case .address: .address
            case .code, .json: .code
            default: nil
            }
        })
    }
}

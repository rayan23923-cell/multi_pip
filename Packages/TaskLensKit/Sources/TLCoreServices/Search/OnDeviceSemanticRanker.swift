import Foundation
import NaturalLanguage

/// Meaning-based ranking with the OS's on-device sentence embeddings
/// (NaturalLanguage). No model is downloaded by TaskLens and no text leaves
/// the device. Languages without an embedding on this OS (Arabic on many
/// versions) report unavailable, and search stays keyword-only.
public final class OnDeviceSemanticRanker: SemanticRanking, @unchecked Sendable {
    private let lock = NSLock()
    private var embeddings: [NLLanguage: NLEmbedding?] = [:]
    private var vectors: [String: [Double]] = [:]
    private static let vectorCacheLimit = 2_000

    public init() {}

    public func isAvailable(for text: String) -> Bool {
        guard let language = Self.language(of: text) else { return false }
        return embedding(for: language) != nil
    }

    public func distance(between query: String, and text: String) -> Double? {
        guard let language = Self.language(of: query), let embedding = embedding(for: language) else { return nil }
        // Only compare text in the same language: vectors of different models don't compare.
        if let textLanguage = Self.language(of: text), textLanguage != language { return nil }
        guard let lhs = vector(query, embedding: embedding, language: language),
              let rhs = vector(text, embedding: embedding, language: language) else { return nil }
        return Self.cosineDistance(lhs, rhs)
    }

    static func language(of text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }

    private func embedding(for language: NLLanguage) -> NLEmbedding? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = embeddings[language] { return cached }
        let embedding = NLEmbedding.sentenceEmbedding(for: language)
        embeddings[language] = .some(embedding)
        return embedding
    }

    private func vector(_ text: String, embedding: NLEmbedding, language: NLLanguage) -> [Double]? {
        let key = language.rawValue + "|" + text
        lock.lock()
        if let cached = vectors[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        guard let vector = embedding.vector(for: text) else { return nil }
        lock.lock()
        if vectors.count >= Self.vectorCacheLimit { vectors.removeAll(keepingCapacity: true) }
        vectors[key] = vector
        lock.unlock()
        return vector
    }

    /// 0 = same direction, 2 = opposite.
    static func cosineDistance(_ lhs: [Double], _ rhs: [Double]) -> Double? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        var dot = 0.0, left = 0.0, right = 0.0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            left += lhs[index] * lhs[index]
            right += rhs[index] * rhs[index]
        }
        guard left > 0, right > 0 else { return nil }
        return 1 - dot / (left.squareRoot() * right.squareRoot())
    }
}

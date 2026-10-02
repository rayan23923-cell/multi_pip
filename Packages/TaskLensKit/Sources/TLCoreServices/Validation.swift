import Foundation
import TLDomain
import TLFoundation

enum Validation {
    /// Trims whitespace and enforces non-empty and maximum length.
    static func name(_ raw: String, maximumLength: Int) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TaskLensError.validationFailed(.emptyName) }
        guard trimmed.count <= maximumLength else { throw TaskLensError.validationFailed(.nameTooLong) }
        return trimmed
    }

    /// Optional titles: empty input becomes `nil`.
    static func optionalTitle(_ raw: String?, maximumLength: Int) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= maximumLength else { throw TaskLensError.validationFailed(.nameTooLong) }
        return trimmed
    }

    static func content(_ content: ContextContent) throws -> ContextContent {
        switch content {
        case .text(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TaskLensError.validationFailed(.emptyContent)
            }
            guard text.count <= ContextItem.maximumTextLength else {
                throw TaskLensError.validationFailed(.contentTooLarge)
            }
            return content
        case .url(let url):
            guard let scheme = url.scheme, !scheme.isEmpty else {
                throw TaskLensError.validationFailed(.invalidURL)
            }
            return content
        case .file(let reference):
            guard !reference.relativePath.isEmpty else {
                throw TaskLensError.validationFailed(.emptyContent)
            }
            return content
        }
    }
}

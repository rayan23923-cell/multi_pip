import SwiftUI
import TLCoreServices
import TLDomain
import TLLocalization

/// What opening an imported PowerPoint file shows until slides can be rendered.
public struct PowerPointDocumentView: View {
    private let documentID: DocumentID
    private let documentService: DocumentService
    @State private var document: Document?

    public init(documentID: DocumentID, documentService: DocumentService) {
        self.documentID = documentID
        self.documentService = documentService
    }

    public var body: some View {
        ContentUnavailableView {
            Label {
                Text(verbatim: document?.title ?? "")
            } icon: {
                Image(systemName: PowerPointDocumentView.symbolName)
            }
        } description: {
            Text(L10nKey.documentsPowerpointNotYet)
        }
        .accessibilityIdentifier("powerpoint.placeholder")
        .navigationTitle(Text(L10nKey.documentsKindPowerpoint))
        .navigationBarTitleDisplayMode(.inline)
        .task { document = try? await documentService.document(id: documentID) }
    }

    static let symbolName = "rectangle.on.rectangle"
}

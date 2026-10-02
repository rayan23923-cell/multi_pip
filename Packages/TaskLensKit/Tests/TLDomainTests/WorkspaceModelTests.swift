import Foundation
import Testing
@testable import TLDomain
import TLFoundation

@Suite("Workspace model")
struct WorkspaceModelTests {
    @Test(arguments: WorkspaceKind.allKnown)
    func kindProvidesDefaults(kind: WorkspaceKind) {
        let workspace = Workspace(name: "W", kind: kind, createdAt: Fixtures.date)
        #expect(workspace.symbolName == kind.defaultSymbolName)
        #expect(workspace.color == kind.defaultColor)
        #expect(workspace.tools == kind.defaultTools)
        #expect(!workspace.tools.isEmpty)
        #expect(workspace.settings.defaultSessionKind == kind.defaultSessionKind)
        #expect(workspace.isFavorite == false)
        #expect(workspace.lastOpenedAt == nil)
    }

    @Test func roundTripsAllFields() throws {
        let workspace = Workspace(
            name: "Thesis",
            kind: .study,
            symbolName: "graduationcap",
            color: .teal,
            tools: [.lens, .notes],
            settings: WorkspaceSettings(defaultSessionKind: .research, resumesLastSession: true),
            isFavorite: true,
            sortOrder: 3,
            createdAt: Fixtures.date,
            lastOpenedAt: Fixtures.date.addingTimeInterval(10)
        )
        #expect(try Fixtures.roundTrip(workspace) == workspace)
    }

    @Test func decodesStoresWrittenBeforeKindsExisted() throws {
        // Shape written by Phase 2 builds: no kind, tools, settings, favorite or lastOpened.
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","name":"Old","symbolName":null,"color":"green","isArchived":false,
         "sortOrder":2,"createdAt":10,"updatedAt":20,"metadata":{}}
        """
        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        #expect(workspace.id.rawValue == id)
        #expect(workspace.name == "Old")
        #expect(workspace.kind == .custom)
        #expect(workspace.color == .green)
        #expect(workspace.symbolName == WorkspaceKind.custom.defaultSymbolName)
        #expect(workspace.tools == WorkspaceKind.custom.defaultTools)
        #expect(workspace.isFavorite == false)
        #expect(workspace.sortOrder == 2)
        #expect(workspace.updatedAt == Date(timeIntervalSinceReferenceDate: 20))
    }

    @Test func draftKindSwitchKeepsUserChoices() {
        var draft = WorkspaceDraft(name: "X", kind: .custom)
        draft.applyKind(.shopping)
        #expect(draft.symbolName == WorkspaceKind.shopping.defaultSymbolName)
        #expect(draft.tools == WorkspaceKind.shopping.defaultTools)
        #expect(draft.settings.defaultSessionKind == .shopping)

        draft.symbolName = "star"
        draft.color = .pink
        draft.applyKind(.study)
        #expect(draft.kind == .study)
        #expect(draft.symbolName == "star")
        #expect(draft.color == .pink)
        #expect(draft.tools == WorkspaceKind.study.defaultTools)
    }

    @Test func draftFromWorkspaceCopiesEditableFields() {
        let workspace = Workspace(name: "Dev", kind: .developer, color: .orange, createdAt: Fixtures.date)
        let draft = WorkspaceDraft(workspace)
        #expect(draft.name == "Dev")
        #expect(draft.kind == .developer)
        #expect(draft.color == .orange)
        #expect(draft.tools == workspace.tools)
    }
}

import Foundation
import TLDomain
import TLFoundation

/// Saves what a tool produced into the right session.
///
/// Target: the active session of the tool's workspace, else the most recently
/// active session, else the inbox. Every tool uses this, so "Save to Session"
/// behaves the same everywhere.
public struct ToolCaptureService: Sendable {
    private let capture: CaptureService
    private let sessions: SessionService

    public init(capture: CaptureService, sessions: SessionService) {
        self.capture = capture
        self.sessions = sessions
    }

    @discardableResult
    public func save(_ output: ToolOutput, preferring workspaceID: WorkspaceID?) async throws -> ContextItem {
        let target = try await sessions.captureTarget(preferring: workspaceID)
        return try await capture.capture(output, into: target?.id)
    }

    /// Saves into a specific session the user picked.
    @discardableResult
    public func save(_ output: ToolOutput, into sessionID: SessionID) async throws -> ContextItem {
        try await capture.capture(output, into: sessionID)
    }

    /// Sessions a tool can attach to: active first, then paused, most recent first.
    /// With a workspace, its sessions come first.
    public func attachableSessions(preferring workspaceID: WorkspaceID?, limit: Int = 20) async throws -> [Session] {
        let active = try await sessions.activeSessions()
        let paused = try await sessions.recentSessions(limit: limit).filter { !$0.isEnded }
        let all = active + paused
        guard let workspaceID else { return Array(all.prefix(limit)) }
        let inWorkspace = all.filter { $0.workspaceID == workspaceID }
        let others = all.filter { $0.workspaceID != workspaceID }
        return Array((inWorkspace + others).prefix(limit))
    }
}

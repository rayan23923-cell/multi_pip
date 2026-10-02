import Foundation
import TLCoreServices
import TLDomain

/// AI stand-ins for UI tests only. `-TaskLensAIFake` answers on "device";
/// `-TaskLensAIOffline` behaves like a server with no network. Release builds
/// always use the real providers.
enum AITestProviders {
    static func make(arguments: [String]) -> [any AIProvider]? {
        #if DEBUG
        if arguments.contains("-TaskLensAIFake") { return [EchoProvider()] }
        if arguments.contains("-TaskLensAIOffline") { return [OfflineProvider()] }
        #endif
        return nil
    }

    #if DEBUG
    struct EchoProvider: AIProvider {
        var kind: AIProviderKind { .onDevice }
        var destination: String { "device" }
        func availability() async -> AIAvailability { .available }
        func respond(to request: AIRequest) async throws -> String {
            let content = request.prompt.components(separatedBy: "\n").dropFirst().first ?? ""
            return "Summary: \(content)\nACTIONS: createNote, call"
        }
    }

    struct OfflineProvider: AIProvider {
        var kind: AIProviderKind { .server }
        var destination: String { "ai.example.com" }
        func availability() async -> AIAvailability { .unavailable(.offline) }
        func respond(to request: AIRequest) async throws -> String { throw AIProviderError.offline }
    }
    #endif
}

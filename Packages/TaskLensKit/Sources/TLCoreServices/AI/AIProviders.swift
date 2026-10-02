import Foundation
import Network
import Security
import TLDomain
import TLFoundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: Apple Intelligence (on device)

/// Apple's on-device model (Foundation Models, iOS 26+ on devices with Apple
/// Intelligence). Text never leaves the device and it works offline.
/// Unavailable on iPhone 11 and older, and before iOS 26.
public struct AppleIntelligenceProvider: AIProvider {
    public init() {}

    public var kind: AIProviderKind { .onDevice }
    public var destination: String { "device" }

    public func availability() async -> AIAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return .unavailable(.deviceNotEligible)
            case .unavailable(.appleIntelligenceNotEnabled):
                return .unavailable(.notEnabled)
            case .unavailable(.modelNotReady):
                return .unavailable(.modelNotReady)
            case .unavailable:
                return .unavailable(.deviceNotEligible)
            }
        }
        #endif
        return .unavailable(.deviceNotEligible)
    }

    public func respond(to request: AIRequest) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let session = LanguageModelSession(instructions: request.instructions)
            let response = try await session.respond(to: request.prompt)
            return response.content
        }
        #endif
        throw AIProviderError.notConfigured
    }
}

// MARK: The user's AI server

/// Where the server API key is kept.
public protocol SecretStoring: Sendable {
    func secret(for key: String) -> String?
    func setSecret(_ value: String?, for key: String)
}

/// The Keychain, this device only (not synced, not in backups).
public struct KeychainSecretStore: SecretStoring {
    private let service: String

    public init(service: String = "TaskLens.AI") {
        self.service = service
    }

    public func secret(for key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String?, for key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var query = baseQuery(key)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
}

public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func secret(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    public func setSecret(_ value: String?, for key: String) {
        lock.lock()
        values[key] = value
        lock.unlock()
    }
}

/// An AI server the user adds in Settings (any service with an
/// OpenAI-compatible chat completions API). Off until the user turns it on.
/// Only the request's text is sent; never images, frames, or the store.
public struct AIServerProvider: AIProvider {
    public static let apiKeySecret = "serverAPIKey"
    public static let timeout: TimeInterval = 30

    private let settings: any AISettingsStoring
    private let secrets: any SecretStoring
    private let network: any NetworkStatusProviding
    private let session: URLSession

    public init(settings: any AISettingsStoring, secrets: any SecretStoring, network: any NetworkStatusProviding, session: URLSession = .shared) {
        self.settings = settings
        self.secrets = secrets
        self.network = network
        self.session = session
    }

    public var kind: AIProviderKind { .server }

    public var destination: String {
        settings.load().serverURL?.host() ?? ""
    }

    public func availability() async -> AIAvailability {
        let settings = settings.load()
        guard settings.allowsServer, AISettings.isValidServerURL(settings.serverURL), !settings.serverModel.isEmpty else {
            return .unavailable(.notConfigured)
        }
        return network.isOnline ? .available : .unavailable(.offline)
    }

    public func respond(to request: AIRequest) async throws -> String {
        let settings = settings.load()
        guard settings.allowsServer, AISettings.isValidServerURL(settings.serverURL), let url = settings.serverURL else {
            throw AIProviderError.notConfigured
        }
        guard network.isOnline else { throw AIProviderError.offline }
        var urlRequest = URLRequest(url: url, timeoutInterval: Self.timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = secrets.secret(for: Self.apiKeySecret), !key.isEmpty {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try JSONEncoder().encode(ChatRequest(
            model: settings.serverModel,
            messages: [.init(role: "system", content: request.instructions), .init(role: "user", content: request.prompt)]
        ))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost].contains(error.code) {
            throw AIProviderError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AIProviderError.badResponse(status: status) }
        guard let reply = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = reply.choices.first?.message.content, !content.isEmpty else {
            throw AIProviderError.unreadableResponse
        }
        return content
    }

    struct ChatRequest: Codable, Equatable {
        struct Message: Codable, Equatable {
            var role: String
            var content: String
        }
        var model: String
        var messages: [Message]
    }

    struct ChatResponse: Codable {
        struct Choice: Codable {
            struct Message: Codable {
                var content: String?
            }
            var message: Message
        }
        var choices: [Choice]
    }
}

// MARK: Network

/// Network reachability from `NWPathMonitor`. No requests are made to check it.
public final class NetworkMonitor: NetworkStatusProviding, @unchecked Sendable {
    public static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.lock()
            online = path.status == .satisfied
            lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "TaskLens.NetworkMonitor"))
    }

    deinit {
        monitor.cancel()
    }

    public var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return online
    }
}

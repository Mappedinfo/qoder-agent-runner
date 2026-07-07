import Foundation

public struct QoderSessionInfo: Decodable {
    public let id: String
    public let status: String?
}

public enum QoderClientError: LocalizedError {
    case invalidResponse
    case httpStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Qoder API"
        case .httpStatus(let code, let body):
            return "Qoder API returned HTTP \(code): \(body)"
        }
    }
}

public enum QoderNetworkMode: String, Codable, CaseIterable {
    case auto
    case direct
    case system

    public static let defaultMode: QoderNetworkMode = .auto

    public var usesAppProxyByDefault: Bool {
        self == .system
    }

    public var description: String {
        switch self {
        case .auto:
            return "auto"
        case .direct:
            return "direct"
        case .system:
            return "system"
        }
    }

    public var diagnosticNote: String {
        switch self {
        case .auto:
            return "Network mode auto first disables env proxies and URLSession proxy settings, then falls back to system networking only when direct hostname resolution/connectivity fails. OS-level TUN/VPN routing can still intercept traffic."
        case .direct:
            return "Network mode direct clears HTTP_PROXY, HTTPS_PROXY, ALL_PROXY, and URLSession proxy settings. OS-level TUN/VPN routing can still intercept traffic."
        case .system:
            return "Network mode system uses the system URLSession networking behavior. This may use macOS proxy/VPN/TUN routing."
        }
    }
}

public final class QoderClient {
    private let token: String
    private let baseURL: URL
    private let session: URLSession
    public let networkMode: QoderNetworkMode

    public init(
        token: String,
        baseURL: URL = QoderDefaults.apiBaseURL,
        networkMode: QoderNetworkMode = .direct,
        protocolClasses: [AnyClass]? = nil
    ) {
        self.token = token
        self.baseURL = baseURL
        self.networkMode = networkMode
        if networkMode != .system {
            Self.clearProxyEnvironmentForCurrentProcess()
        }

        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        if networkMode != .system {
            configuration.connectionProxyDictionary = [:]
        }
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public static func clearProxyEnvironmentForCurrentProcess() {
        for key in [
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
            "http_proxy", "https_proxy", "all_proxy", "no_proxy"
        ] {
            unsetenv(key)
        }
    }

    public func createSession(
        agentID: String,
        agentVersion: Int? = nil,
        environmentID: String,
        metadata: [String: String]? = nil
    ) async throws -> (QoderSessionInfo, Data) {
        var request = jsonRequest(path: "sessions", method: "POST")
        let body = CreateSessionBody(
            agent: AgentReference(id: agentID, version: agentVersion),
            environment_id: environmentID,
            metadata: metadata?.isEmpty == false ? metadata : nil
        )
        request.httpBody = try JSONEncoder().encode(body)

        let data = try await perform(request)
        let sessionInfo = try JSONDecoder().decode(QoderSessionInfo.self, from: data)
        return (sessionInfo, data)
    }

    public func cancelSession(sessionID: String) async throws -> Data {
        let request = jsonRequest(path: "sessions/\(sessionID)/cancel", method: "POST")
        return try await perform(request)
    }

    public func sendUserMessage(sessionID: String, prompt: String) async throws -> Data {
        var request = jsonRequest(path: "sessions/\(sessionID)/events", method: "POST")
        let body = SendEventsBody(events: [
            UserMessageEvent(content: [
                MessageContent(type: "text", text: prompt)
            ])
        ])
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    public func streamEvents(
        sessionID: String,
        onRawLine: @escaping (String) throws -> Void,
        onEvent: @escaping (SSEEvent) throws -> Bool
    ) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("sessions/\(sessionID)/events/stream"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw QoderClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw QoderClientError.httpStatus(httpResponse.statusCode, "stream request failed")
        }

        var parser = SSEParser()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            try onRawLine(line + "\n")
            if let event = parser.consume(line: line) {
                let shouldContinue = try onEvent(event)
                if !shouldContinue {
                    return
                }
            }
        }

        if let event = parser.finish() {
            _ = try onEvent(event)
        }
    }

    private func jsonRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw QoderClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw QoderClientError.httpStatus(httpResponse.statusCode, body)
        }
        return data
    }
}

private struct CreateSessionBody: Encodable {
    let agent: AgentReference
    let environment_id: String
    let metadata: [String: String]?
}

private struct AgentReference: Encodable {
    let id: String
    let version: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case version
    }

    func encode(to encoder: Encoder) throws {
        guard let version else {
            var container = encoder.singleValueContainer()
            try container.encode(id)
            return
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode("agent", forKey: .type)
        try container.encode(version, forKey: .version)
    }
}

private struct SendEventsBody: Encodable {
    let events: [UserMessageEvent]
}

private struct UserMessageEvent: Encodable {
    let type = "user.message"
    let content: [MessageContent]
}

private struct MessageContent: Encodable {
    let type: String
    let text: String
}

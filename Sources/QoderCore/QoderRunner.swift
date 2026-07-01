import Foundation

public struct RunConfiguration {
    public var agentID: String
    public var environmentID: String
    public var outputRoot: URL
    public var token: String
    public var profileName: String
    public var configPath: URL?

    public init(
        agentID: String,
        environmentID: String,
        outputRoot: URL,
        token: String,
        profileName: String = "default",
        configPath: URL? = nil
    ) {
        self.agentID = agentID
        self.environmentID = environmentID
        self.outputRoot = outputRoot
        self.token = token
        self.profileName = profileName
        self.configPath = configPath
    }

    public init(resolvedConfig: ResolvedQoderConfig) {
        self.init(
            agentID: resolvedConfig.agentID,
            environmentID: resolvedConfig.environmentID,
            outputRoot: resolvedConfig.outputRoot,
            token: resolvedConfig.token,
            profileName: resolvedConfig.profileName,
            configPath: resolvedConfig.configPath
        )
    }
}

public struct RunCallbacks {
    public var onLog: (String) -> Void
    public var onEvent: (SSEEvent) -> Void

    public init(
        onLog: @escaping (String) -> Void = { _ in },
        onEvent: @escaping (SSEEvent) -> Void = { _ in }
    ) {
        self.onLog = onLog
        self.onEvent = onEvent
    }
}

public struct RunResult {
    public let runDirectory: URL
    public let sessionID: String?
    public let status: String
    public let reportURL: URL
    public let metadataURL: URL
}

public enum QoderRunnerError: LocalizedError {
    case emptyPrompt
    case failed(String, URL?)

    public var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            return "Prompt is empty"
        case .failed(let message, _):
            return message
        }
    }

    public var runDirectory: URL? {
        switch self {
        case .emptyPrompt:
            return nil
        case .failed(_, let runDirectory):
            return runDirectory
        }
    }
}

public final class QoderRunner {
    private let configuration: RunConfiguration

    public init(configuration: RunConfiguration) {
        self.configuration = configuration
    }

    public func run(prompt: String, callbacks: RunCallbacks = RunCallbacks()) async throws -> RunResult {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw QoderRunnerError.emptyPrompt
        }

        let startedAt = Date()
        let recorder = try RunRecorder(outputRoot: configuration.outputRoot, startedAt: startedAt)
        try recorder.writePrompt(prompt)

        var sessionID: String?
        var finalStatus = "started"
        var stopReason: Any?
        var lastAgentMessage: String?

        func writeMetadata(status: String, error: String? = nil) {
            var object: [String: Any] = [
                "agent_id": configuration.agentID,
                "environment_id": configuration.environmentID,
                "output_root": configuration.outputRoot.path,
                "profile": configuration.profileName,
                "run_dir": recorder.paths.runDirectory.path,
                "started_at": RunRecorder.isoString(startedAt),
                "finished_at": RunRecorder.isoString(Date()),
                "status": status
            ]
            if let configPath = configuration.configPath {
                object["config_path"] = configPath.path
            }
            if let sessionID {
                object["session_id"] = sessionID
            }
            if let stopReason {
                object["stop_reason"] = stopReason
            }
            if let error {
                object["error"] = error
                object["network_note"] = "The runner clears HTTP_PROXY, HTTPS_PROXY, ALL_PROXY, and URLSession proxy settings. OS-level TUN/VPN routing can still intercept traffic."
            }
            if FileManager.default.fileExists(atPath: recorder.paths.report.path) {
                object["report_path"] = recorder.paths.report.path
            }
            try? recorder.writeMetadata(object)
        }

        do {
            callbacks.onLog("Creating session")
            let client = QoderClient(token: configuration.token)
            let (sessionInfo, sessionData) = try await client.createSession(
                agentID: configuration.agentID,
                environmentID: configuration.environmentID
            )
            sessionID = sessionInfo.id
            try recorder.writeSessionJSON(sessionData)
            finalStatus = "session_created"
            writeMetadata(status: finalStatus)

            callbacks.onLog("Sending prompt")
            _ = try await client.sendUserMessage(sessionID: sessionInfo.id, prompt: prompt)

            callbacks.onLog("Streaming events")
            try await client.streamEvents(
                sessionID: sessionInfo.id,
                onRawLine: { line in
                    try recorder.appendSSELine(line)
                },
                onEvent: { event in
                    callbacks.onEvent(event)
                    if let data = event.data {
                        try recorder.appendEventJSONLine(data)
                        if let message = Self.agentMessageText(from: data) {
                            lastAgentMessage = message
                        }
                        if let parsedStopReason = Self.stopReason(from: data) {
                            stopReason = parsedStopReason
                        }
                    }

                    if event.name == "session.status_idle" {
                        finalStatus = "idle"
                        return false
                    }
                    return true
                }
            )

            if finalStatus != "idle" {
                finalStatus = "stream_ended"
            }
            try recorder.writeReport(lastAgentMessage ?? "")
            writeMetadata(status: finalStatus)
            callbacks.onLog("Finished: \(finalStatus)")

            return RunResult(
                runDirectory: recorder.paths.runDirectory,
                sessionID: sessionID,
                status: finalStatus,
                reportURL: recorder.paths.report,
                metadataURL: recorder.paths.metadata
            )
        } catch is CancellationError {
            if let lastAgentMessage {
                try? recorder.writeReport(lastAgentMessage)
            }
            writeMetadata(status: "cancelled")
            callbacks.onLog("Cancelled")
            throw QoderRunnerError.failed("Run cancelled", recorder.paths.runDirectory)
        } catch {
            if let lastAgentMessage {
                try? recorder.writeReport(lastAgentMessage)
            }
            let message = Self.diagnosticMessage(for: error)
            writeMetadata(status: "failed", error: message)
            callbacks.onLog("Failed: \(message)")
            throw QoderRunnerError.failed(message, recorder.paths.runDirectory)
        }
    }

    private static func agentMessageText(from json: String) -> String? {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            (object["type"] as? String) == "agent.message",
            let content = object["content"] as? [[String: Any]]
        else {
            return nil
        }

        let text = content.compactMap { item -> String? in
            guard (item["type"] as? String) == "text" else { return nil }
            return item["text"] as? String
        }.joined()

        return text.isEmpty ? nil : text
    }

    private static func stopReason(from json: String) -> Any? {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            (object["type"] as? String) == "session.status_idle"
        else {
            return nil
        }
        return object["stop_reason"]
    }

    private static func diagnosticMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            return "\(urlError.localizedDescription). Direct mode is enabled: env proxies and URLSession proxy settings are disabled; if traffic is still captured, check OS-level TUN/VPN routing."
        }
        return error.localizedDescription
    }
}

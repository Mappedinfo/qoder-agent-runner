import Foundation

public struct RunConfiguration {
    public var baseURL: URL
    public var agentID: String
    public var agentVersion: Int?
    public var environmentID: String
    public var outputRoot: URL
    public var runID: String?
    public var runDirectory: URL?
    public var token: String
    public var profileName: String
    public var configPath: URL?
    public var metadata: [String: String]

    public init(
        baseURL: URL = QoderDefaults.apiBaseURL,
        agentID: String,
        agentVersion: Int? = nil,
        environmentID: String,
        outputRoot: URL,
        runID: String? = nil,
        runDirectory: URL? = nil,
        token: String,
        profileName: String = "default",
        configPath: URL? = nil,
        metadata: [String: String] = [:]
    ) {
        self.baseURL = baseURL
        self.agentID = agentID
        self.agentVersion = agentVersion
        self.environmentID = environmentID
        self.outputRoot = outputRoot
        self.runID = runID
        self.runDirectory = runDirectory
        self.token = token
        self.profileName = profileName
        self.configPath = configPath
        self.metadata = metadata
    }

    public init(resolvedConfig: ResolvedQoderConfig) {
        self.init(
            baseURL: resolvedConfig.baseURL,
            agentID: resolvedConfig.agentID,
            agentVersion: resolvedConfig.agentVersion,
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
    public let summaryURL: URL
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
        let recorder = try RunRecorder(
            outputRoot: configuration.outputRoot,
            startedAt: startedAt,
            runID: configuration.runID,
            runDirectory: configuration.runDirectory
        )
        try recorder.writePrompt(prompt)

        var sessionID: String?
        var finalStatus = "started"
        var stopReason: Any?
        var lastAgentMessage: String?
        var primaryReportContent: String?
        var artifactRecords: [[String: Any]] = []
        var pendingDeliveries: [[String: Any]] = []
        var deliveredArtifacts: [[String: Any]] = []

        func writeMetadata(status: String, error: String? = nil) {
            var object: [String: Any] = [
                "agent_id": configuration.agentID,
                "base_url": configuration.baseURL.absoluteString,
                "environment_id": configuration.environmentID,
                "output_root": configuration.outputRoot.path,
                "profile": configuration.profileName,
                "run_dir": recorder.paths.runDirectory.path,
                "started_at": RunRecorder.isoString(startedAt),
                "finished_at": RunRecorder.isoString(Date()),
                "status": status
            ]
            if let agentVersion = configuration.agentVersion {
                object["agent_version"] = agentVersion
            }
            if let runID = configuration.runID {
                object["run_id"] = runID
            }
            if !configuration.metadata.isEmpty {
                object["session_metadata"] = configuration.metadata
            }
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
            if FileManager.default.fileExists(atPath: recorder.paths.summary.path) {
                object["summary_path"] = recorder.paths.summary.path
            }
            if !artifactRecords.isEmpty {
                object["artifacts"] = artifactRecords
            }
            if !pendingDeliveries.isEmpty {
                object["deliver_artifacts_requests"] = pendingDeliveries
            }
            if !deliveredArtifacts.isEmpty {
                object["delivered_artifacts"] = deliveredArtifacts
            }
            try? recorder.writeMetadata(object)
        }

        do {
            callbacks.onLog("Creating session")
            let client = QoderClient(token: configuration.token, baseURL: configuration.baseURL)
            let (sessionInfo, sessionData) = try await client.createSession(
                agentID: configuration.agentID,
                agentVersion: configuration.agentVersion,
                environmentID: configuration.environmentID,
                metadata: configuration.metadata
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
                        if let writeArtifact = Self.writeArtifact(from: data) {
                            let localURL = try recorder.writeArtifact(
                                originalPath: writeArtifact.filePath,
                                content: writeArtifact.content
                            )
                            if primaryReportContent == nil {
                                primaryReportContent = writeArtifact.content
                            }
                            var record: [String: Any] = [
                                "tool": "Write",
                                "local_path": localURL.path,
                                "bytes": Data(writeArtifact.content.utf8).count
                            ]
                            record["event_id"] = writeArtifact.eventID
                            record["source_path"] = writeArtifact.filePath
                            artifactRecords.append(record)
                        }
                        if let delivery = Self.deliverArtifactsRequest(from: data) {
                            pendingDeliveries.append(delivery)
                        }
                        if let delivered = Self.deliveredArtifact(from: data) {
                            deliveredArtifacts.append(delivered)
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
            try recorder.writeReport(primaryReportContent ?? lastAgentMessage ?? "")
            if let lastAgentMessage {
                try recorder.writeSummary(lastAgentMessage)
            }
            writeMetadata(status: finalStatus)
            callbacks.onLog("Finished: \(finalStatus)")

            return RunResult(
                runDirectory: recorder.paths.runDirectory,
                sessionID: sessionID,
                status: finalStatus,
                reportURL: recorder.paths.report,
                summaryURL: recorder.paths.summary,
                metadataURL: recorder.paths.metadata
            )
        } catch is CancellationError {
            if let sessionID {
                await cancelRemoteSession(sessionID: sessionID, callbacks: callbacks)
            }
            if let primaryReportContent {
                try? recorder.writeReport(primaryReportContent)
            } else if let lastAgentMessage {
                try? recorder.writeReport(lastAgentMessage)
            }
            if let lastAgentMessage {
                try? recorder.writeSummary(lastAgentMessage)
            }
            writeMetadata(status: "cancelled")
            callbacks.onLog("Cancelled")
            throw QoderRunnerError.failed("Run cancelled", recorder.paths.runDirectory)
        } catch {
            if let primaryReportContent {
                try? recorder.writeReport(primaryReportContent)
            } else if let lastAgentMessage {
                try? recorder.writeReport(lastAgentMessage)
            }
            if let lastAgentMessage {
                try? recorder.writeSummary(lastAgentMessage)
            }
            let message = Self.diagnosticMessage(for: error)
            writeMetadata(status: "failed", error: message)
            callbacks.onLog("Failed: \(message)")
            throw QoderRunnerError.failed(message, recorder.paths.runDirectory)
        }
    }

    private func cancelRemoteSession(sessionID: String, callbacks: RunCallbacks) async {
        let token = configuration.token
        let baseURL = configuration.baseURL
        callbacks.onLog("Cancelling remote session")
        do {
            try await Task.detached(priority: .utility) {
                let client = QoderClient(token: token, baseURL: baseURL)
                _ = try await client.cancelSession(sessionID: sessionID)
            }.value
            callbacks.onLog("Remote session cancelled")
        } catch {
            callbacks.onLog("Remote cancel failed: \(error.localizedDescription)")
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

    private struct WriteArtifact {
        let eventID: String?
        let filePath: String?
        let content: String
    }

    private static func writeArtifact(from json: String) -> WriteArtifact? {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            (object["type"] as? String) == "agent.tool_use",
            (object["name"] as? String) == "Write",
            let input = object["input"] as? [String: Any],
            let content = input["content"] as? String,
            !content.isEmpty
        else {
            return nil
        }

        return WriteArtifact(
            eventID: object["id"] as? String,
            filePath: input["file_path"] as? String,
            content: content
        )
    }

    private static func deliverArtifactsRequest(from json: String) -> [String: Any]? {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            (object["type"] as? String) == "agent.tool_use",
            (object["name"] as? String) == "DeliverArtifacts",
            let input = object["input"] as? [String: Any]
        else {
            return nil
        }

        var request: [String: Any] = [
            "tool": "DeliverArtifacts"
        ]
        request["event_id"] = object["id"] as? String
        if let files = input["files"] {
            request["files"] = files
        }
        return request
    }

    private static func deliveredArtifact(from json: String) -> [String: Any]? {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            (object["type"] as? String) == "agent.artifact_delivered"
        else {
            return nil
        }

        var delivered: [String: Any] = [:]
        delivered["event_id"] = object["id"] as? String
        delivered["file_id"] = object["file_id"] as? String
        delivered["original_filename"] = object["original_filename"] as? String
        delivered["content_type"] = object["content_type"] as? String
        delivered["size"] = object["size"]
        if let processedAt = object["processed_at"] {
            delivered["processed_at"] = processedAt
        }
        return delivered
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

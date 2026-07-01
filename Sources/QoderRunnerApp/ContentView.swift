import AppKit
import QoderCore
import SwiftUI

struct ContentView: View {
    @StateObject private var model = RunnerViewModel()

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Circle()
                    .fill(model.statusColor)
                    .frame(width: 12, height: 12)
                Text(model.statusText)
                    .font(.headline)
                Spacer()
                Button("Copy Session") {
                    model.copySessionID()
                }
                .disabled(model.sessionID == nil)
                Button("Open Report") {
                    model.openReport()
                }
                .disabled(model.reportURL == nil)
                Button("Reveal Folder") {
                    model.revealRunFolder()
                }
                .disabled(model.runDirectory == nil)
                Button("Reload Config") {
                    model.loadConfig()
                }
            }

            TextEditor(text: $model.prompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                )

            DisclosureGroup("Advanced", isExpanded: $model.showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    labeledField("Config", text: $model.configPath)
                    labeledField("Profile", text: $model.profileName)
                    labeledField("Agent", text: $model.agentID)
                    labeledField("Environment", text: $model.environmentID)
                    labeledField("Output root", text: $model.outputRootPath)
                    labeledField("Token env", text: $model.tokenEnv)
                    HStack {
                        Text("Token")
                            .frame(width: 90, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        SecureField("Optional one-run token override; not saved", text: $model.tokenOverride)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.top, 8)
            }

            HStack {
                Button("Send") {
                    model.send()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!model.canSend)

                Button("Cancel") {
                    model.cancel()
                }
                .disabled(!model.isRunning)

                Spacer()
            }

            HSplitView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Events")
                        .font(.headline)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(model.logs.indices, id: \.self) { index in
                                Text(model.logs[index])
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                    }
                    .background(Color(NSColor.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Files")
                        .font(.headline)
                    List(model.files, id: \.path) { file in
                        Button(file.lastPathComponent) {
                            NSWorkspace.shared.open(file)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(minWidth: 240)
            }
        }
        .padding(16)
    }

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .frame(width: 90, alignment: .trailing)
                .foregroundStyle(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

@MainActor
final class RunnerViewModel: ObservableObject {
    @Published var prompt = ""
    @Published var configPath = QoderConfigResolver.defaultConfigURL().path
    @Published var profileName = "default"
    @Published var agentID = ""
    @Published var environmentID = ""
    @Published var outputRootPath = QoderDefaults.defaultOutputRoot.path
    @Published var tokenEnv = QoderDefaults.defaultTokenEnvironmentVariable
    @Published var tokenOverride = ""
    @Published var showAdvanced = false
    @Published var logs: [String] = []
    @Published var files: [URL] = []
    @Published var sessionID: String?
    @Published var runDirectory: URL?
    @Published var reportURL: URL?
    @Published var state: RunnerState = .idle

    private var task: Task<Void, Never>?

    init() {
        loadConfig()
    }

    var isRunning: Bool {
        state == .running
    }

    var canSend: Bool {
        !isRunning
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !agentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !environmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasToken
    }

    var statusText: String {
        if state == .idle && !hasToken {
            return "Missing Token"
        }
        if state == .idle && (agentID.isEmpty || environmentID.isEmpty) {
            return "Missing Config"
        }
        switch state {
        case .idle:
            return "Idle"
        case .running:
            return "Running"
        case .success:
            return "Finished"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    var statusColor: Color {
        if state == .idle && (!hasToken || agentID.isEmpty || environmentID.isEmpty) {
            return .red
        }
        switch state {
        case .idle:
            return .gray
        case .running:
            return .yellow
        case .success:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
        }
    }

    private var hasToken: Bool {
        let override = tokenOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return true }
        let envName = tokenEnv.trimmingCharacters(in: .whitespacesAndNewlines)
        return !envName.isEmpty && ProcessInfo.processInfo.environment[envName] != nil
    }

    func loadConfig() {
        do {
            let path = URL(fileURLWithPath: configPath)
            let resolved = try QoderConfigResolver.resolve(
                configPath: path,
                profileName: profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : profileName,
                overrides: QoderConfigOverrides(tokenOverride: tokenOverride)
            )
            profileName = resolved.profileName
            agentID = resolved.agentID
            environmentID = resolved.environmentID
            outputRootPath = resolved.outputRoot.path
            tokenEnv = resolved.tokenEnv
            appendLog("config loaded: \(resolved.configPath?.path ?? "defaults")")
            state = .idle
        } catch QoderConfigError.missingToken {
            loadConfigIgnoringToken()
            appendLog("config loaded; token missing")
            state = .idle
        } catch {
            appendLog("config error: \(error.localizedDescription)")
            state = .failed
        }
    }

    func send() {
        guard canSend else { return }

        logs.removeAll()
        files.removeAll()
        sessionID = nil
        runDirectory = nil
        reportURL = nil
        state = .running

        let currentPrompt = prompt
        let currentConfigPath = configPath
        let currentProfileName = profileName
        let currentTokenOverride = tokenOverride
        let overrides = QoderConfigOverrides(
            agentID: agentID,
            environmentID: environmentID,
            outputRoot: URL(fileURLWithPath: outputRootPath, isDirectory: true),
            tokenEnv: tokenEnv,
            tokenOverride: currentTokenOverride
        )

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let resolvedConfig = try QoderConfigResolver.resolve(
                    configPath: URL(fileURLWithPath: currentConfigPath),
                    profileName: currentProfileName,
                    overrides: overrides
                )
                let configuration = RunConfiguration(resolvedConfig: resolvedConfig)
                let runner = QoderRunner(configuration: configuration)
                let callbacks = RunCallbacks(
                    onLog: { message in
                        Task { @MainActor in
                            self.appendLog(message)
                        }
                    },
                    onEvent: { event in
                        Task { @MainActor in
                            self.appendLog("event: \(event.name)")
                        }
                    }
                )

                let result = try await runner.run(prompt: currentPrompt, callbacks: callbacks)
                self.sessionID = result.sessionID
                self.runDirectory = result.runDirectory
                self.reportURL = result.reportURL
                self.refreshFiles()
                self.state = .success
            } catch {
                if Task.isCancelled {
                    self.state = .cancelled
                } else {
                    self.state = .failed
                }
                if let runnerError = error as? QoderRunnerError, let runDirectory = runnerError.runDirectory {
                    self.runDirectory = runDirectory
                    self.refreshFiles()
                }
                self.appendLog("error: \(error.localizedDescription)")
            }
            self.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .cancelled
    }

    func openReport() {
        guard let reportURL else { return }
        NSWorkspace.shared.open(reportURL)
    }

    func revealRunFolder() {
        guard let runDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([runDirectory])
    }

    func copySessionID() {
        guard let sessionID else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sessionID, forType: .string)
    }

    private func appendLog(_ message: String) {
        logs.append("[\(Self.timeFormatter.string(from: Date()))] \(message)")
        if logs.count > 300 {
            logs.removeFirst(logs.count - 300)
        }
    }

    private func refreshFiles() {
        guard let runDirectory else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: runDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        files = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let report = runDirectory.appendingPathComponent("report.md")
        if FileManager.default.fileExists(atPath: report.path) {
            reportURL = report
        }
    }

    private func loadConfigIgnoringToken() {
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
            let configFile = try? JSONDecoder().decode(QoderConfigFile.self, from: data)
        else {
            return
        }
        let requested = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedProfileName = requested.isEmpty ? (configFile.activeProfile ?? configFile.profiles.keys.sorted().first ?? "default") : requested
        guard let profile = configFile.profiles[selectedProfileName] else { return }
        profileName = selectedProfileName
        agentID = profile.agentID ?? ""
        environmentID = profile.environmentID ?? ""
        if let outputRoot = profile.outputRoot {
            outputRootPath = QoderConfigResolver.expandPath(outputRoot).path
        }
        tokenEnv = profile.tokenEnv ?? QoderDefaults.defaultTokenEnvironmentVariable
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

enum RunnerState {
    case idle
    case running
    case success
    case failed
    case cancelled
}

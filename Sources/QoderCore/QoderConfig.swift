import Foundation

public struct QoderConfigFile: Codable {
    public var activeProfile: String?
    public var profiles: [String: QoderProfileConfig]

    enum CodingKeys: String, CodingKey {
        case activeProfile = "active_profile"
        case profiles
    }
}

public struct QoderProfileConfig: Codable {
    public var agentID: String?
    public var environmentID: String?
    public var outputRoot: String?
    public var tokenEnv: String?

    public init(
        agentID: String? = nil,
        environmentID: String? = nil,
        outputRoot: String? = nil,
        tokenEnv: String? = nil
    ) {
        self.agentID = agentID
        self.environmentID = environmentID
        self.outputRoot = outputRoot
        self.tokenEnv = tokenEnv
    }

    enum CodingKeys: String, CodingKey {
        case agentID = "agent_id"
        case environmentID = "environment_id"
        case outputRoot = "output_root"
        case tokenEnv = "token_env"
    }
}

public struct QoderConfigOverrides {
    public var agentID: String?
    public var environmentID: String?
    public var outputRoot: URL?
    public var tokenEnv: String?
    public var tokenOverride: String?

    public init(
        agentID: String? = nil,
        environmentID: String? = nil,
        outputRoot: URL? = nil,
        tokenEnv: String? = nil,
        tokenOverride: String? = nil
    ) {
        self.agentID = agentID
        self.environmentID = environmentID
        self.outputRoot = outputRoot
        self.tokenEnv = tokenEnv
        self.tokenOverride = tokenOverride
    }
}

public struct ResolvedQoderConfig {
    public let profileName: String
    public let configPath: URL?
    public let agentID: String
    public let environmentID: String
    public let outputRoot: URL
    public let tokenEnv: String
    public let token: String
}

public enum QoderConfigError: LocalizedError {
    case configFileMissing(String)
    case invalidConfig(String)
    case profileMissing(String)
    case missingAgentID
    case missingEnvironmentID
    case missingToken(String)

    public var errorDescription: String? {
        switch self {
        case .configFileMissing(let path):
            return "Missing config file: \(path)"
        case .invalidConfig(let message):
            return "Invalid config: \(message)"
        case .profileMissing(let profile):
            return "Missing profile in config: \(profile)"
        case .missingAgentID:
            return "Missing agent_id. Set it in config.local.json or pass --agent."
        case .missingEnvironmentID:
            return "Missing environment_id. Set it in config.local.json or pass --environment-id."
        case .missingToken(let tokenEnv):
            return "Missing token. Set \(tokenEnv) in the process environment or provide a temporary token in the UI."
        }
    }
}

public enum QoderConfigResolver {
    public static func defaultConfigURL() -> URL {
        for candidate in defaultConfigCandidates() where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(QoderDefaults.localConfigFileName)
    }

    public static func defaultConfigCandidates() -> [URL] {
        var candidates: [URL] = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(QoderDefaults.localConfigFileName)
        ]

        let bundleURL = Bundle.main.bundleURL
        candidates.append(bundleURL.deletingLastPathComponent().appendingPathComponent(QoderDefaults.localConfigFileName))
        candidates.append(bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(QoderDefaults.localConfigFileName))

        if let executableURL = Bundle.main.executableURL {
            candidates.append(executableURL.deletingLastPathComponent().appendingPathComponent(QoderDefaults.localConfigFileName))
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    public static func resolve(
        configPath: URL? = nil,
        profileName requestedProfile: String? = nil,
        overrides: QoderConfigOverrides = QoderConfigOverrides()
    ) throws -> ResolvedQoderConfig {
        let path = configPath ?? defaultConfigURL()
        let explicitConfigPath = configPath != nil
        let fileExists = FileManager.default.fileExists(atPath: path.path)

        if explicitConfigPath && !fileExists {
            throw QoderConfigError.configFileMissing(path.path)
        }

        let configFile: QoderConfigFile?
        if fileExists {
            do {
                let data = try Data(contentsOf: path)
                configFile = try JSONDecoder().decode(QoderConfigFile.self, from: data)
            } catch {
                throw QoderConfigError.invalidConfig(error.localizedDescription)
            }
        } else {
            configFile = nil
        }

        let profileName = requestedProfile
            ?? configFile?.activeProfile
            ?? configFile?.profiles.keys.sorted().first
            ?? "default"

        let profile: QoderProfileConfig
        if let configFile {
            guard let selected = configFile.profiles[profileName] else {
                throw QoderConfigError.profileMissing(profileName)
            }
            profile = selected
        } else {
            profile = QoderProfileConfig()
        }

        let agentID = clean(overrides.agentID) ?? clean(profile.agentID)
        let environmentID = clean(overrides.environmentID) ?? clean(profile.environmentID)
        let tokenEnv = clean(overrides.tokenEnv) ?? clean(profile.tokenEnv) ?? QoderDefaults.defaultTokenEnvironmentVariable
        let outputRoot = overrides.outputRoot
            ?? profile.outputRoot.flatMap { clean($0) }.map(expandPath(_:))
            ?? QoderDefaults.defaultOutputRoot

        guard let agentID else {
            throw QoderConfigError.missingAgentID
        }
        guard let environmentID else {
            throw QoderConfigError.missingEnvironmentID
        }

        let token = clean(overrides.tokenOverride) ?? clean(ProcessInfo.processInfo.environment[tokenEnv])
        guard let token else {
            throw QoderConfigError.missingToken(tokenEnv)
        }

        return ResolvedQoderConfig(
            profileName: profileName,
            configPath: fileExists ? path : nil,
            agentID: agentID,
            environmentID: environmentID,
            outputRoot: outputRoot,
            tokenEnv: tokenEnv,
            token: token
        )
    }

    public static func expandPath(_ path: String) -> URL {
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

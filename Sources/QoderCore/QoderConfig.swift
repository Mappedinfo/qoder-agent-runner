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
    public var baseURL: String?
    public var agentID: String?
    public var agentVersion: Int?
    public var environmentID: String?
    public var outputRoot: String?
    public var tokenEnv: String?
    public var envFile: String?

    public init(
        baseURL: String? = nil,
        agentID: String? = nil,
        agentVersion: Int? = nil,
        environmentID: String? = nil,
        outputRoot: String? = nil,
        tokenEnv: String? = nil,
        envFile: String? = nil
    ) {
        self.baseURL = baseURL
        self.agentID = agentID
        self.agentVersion = agentVersion
        self.environmentID = environmentID
        self.outputRoot = outputRoot
        self.tokenEnv = tokenEnv
        self.envFile = envFile
    }

    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
        case agentID = "agent_id"
        case agentVersion = "agent_version"
        case environmentID = "environment_id"
        case outputRoot = "output_root"
        case tokenEnv = "token_env"
        case envFile = "env_file"
    }
}

public struct QoderConfigOverrides {
    public var baseURL: URL?
    public var agentID: String?
    public var agentVersion: Int?
    public var environmentID: String?
    public var outputRoot: URL?
    public var tokenEnv: String?
    public var envFile: URL?
    public var tokenOverride: String?

    public init(
        baseURL: URL? = nil,
        agentID: String? = nil,
        agentVersion: Int? = nil,
        environmentID: String? = nil,
        outputRoot: URL? = nil,
        tokenEnv: String? = nil,
        envFile: URL? = nil,
        tokenOverride: String? = nil
    ) {
        self.baseURL = baseURL
        self.agentID = agentID
        self.agentVersion = agentVersion
        self.environmentID = environmentID
        self.outputRoot = outputRoot
        self.tokenEnv = tokenEnv
        self.envFile = envFile
        self.tokenOverride = tokenOverride
    }
}

public struct ResolvedQoderConfig {
    public let profileName: String
    public let configPath: URL?
    public let baseURL: URL
    public let agentID: String
    public let agentVersion: Int?
    public let environmentID: String
    public let outputRoot: URL
    public let tokenEnv: String
    public let envFile: URL?
    public let token: String
}

public enum QoderConfigError: LocalizedError {
    case configFileMissing(String)
    case invalidConfig(String)
    case invalidBaseURL(String)
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
        case .invalidBaseURL(let value):
            return "Invalid base_url: \(value)"
        case .profileMissing(let profile):
            return "Missing profile in config: \(profile)"
        case .missingAgentID:
            return "Missing agent_id. Set it in config.local.json or pass --agent."
        case .missingEnvironmentID:
            return "Missing environment_id. Set it in config.local.json or pass --environment-id."
        case .missingToken(let tokenEnv):
            return "Missing token. Set \(tokenEnv) in the process environment, configure env_file, or provide a temporary token in the UI."
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
        let agentVersion = overrides.agentVersion ?? profile.agentVersion
        let environmentID = clean(overrides.environmentID) ?? clean(profile.environmentID)
        let tokenEnv = clean(overrides.tokenEnv) ?? clean(profile.tokenEnv) ?? QoderDefaults.defaultTokenEnvironmentVariable
        let envFile = overrides.envFile
            ?? profile.envFile.flatMap { clean($0) }.map { resolveEnvFile($0, configURL: fileExists ? path : nil) }
            ?? defaultEnvFile(configURL: fileExists ? path : nil)
        let outputRoot = overrides.outputRoot
            ?? profile.outputRoot.flatMap { clean($0) }.map(expandPath(_:))
            ?? QoderDefaults.defaultOutputRoot
        let baseURL = try overrides.baseURL
            ?? profile.baseURL.flatMap { clean($0) }.map(resolveBaseURL(_:))
            ?? QoderDefaults.apiBaseURL

        guard let agentID else {
            throw QoderConfigError.missingAgentID
        }
        guard let environmentID else {
            throw QoderConfigError.missingEnvironmentID
        }

        let token = clean(overrides.tokenOverride)
            ?? clean(ProcessInfo.processInfo.environment[tokenEnv])
            ?? envFile.flatMap { tokenFromEnvFile(tokenEnv, envFile: $0) }
        guard let token else {
            throw QoderConfigError.missingToken(tokenEnv)
        }

        return ResolvedQoderConfig(
            profileName: profileName,
            configPath: fileExists ? path : nil,
            baseURL: baseURL,
            agentID: agentID,
            agentVersion: agentVersion,
            environmentID: environmentID,
            outputRoot: outputRoot,
            tokenEnv: tokenEnv,
            envFile: envFile,
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

    public static func expandFilePath(_ path: String) -> URL {
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)), isDirectory: false)
        }
        return URL(fileURLWithPath: path, isDirectory: false)
    }

    private static func resolveBaseURL(_ value: String) throws -> URL {
        guard
            let url = URL(string: value),
            let scheme = url.scheme,
            ["http", "https"].contains(scheme),
            url.host != nil
        else {
            throw QoderConfigError.invalidBaseURL(value)
        }
        return url
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func resolveEnvFile(_ value: String, configURL: URL?) -> URL {
        if value == "~" || value.hasPrefix("~/") {
            return expandFilePath(value)
        }
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value, isDirectory: false)
        }
        let base = configURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return base.appendingPathComponent(value, isDirectory: false)
    }

    private static func defaultEnvFile(configURL: URL?) -> URL? {
        var candidates: [URL] = []
        if let configURL {
            candidates.append(configURL.deletingLastPathComponent().appendingPathComponent(".env"))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env"))

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.standardizedFileURL.path).inserted {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func tokenFromEnvFile(_ tokenEnv: String, envFile: URL) -> String? {
        guard
            FileManager.default.fileExists(atPath: envFile.path),
            let text = try? String(contentsOf: envFile, encoding: .utf8)
        else {
            return nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard key == tokenEnv else {
                continue
            }
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.count >= 2 {
                let first = value.first
                let last = value.last
                if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                    value = String(value.dropFirst().dropLast())
                }
            }
            return clean(value)
        }
        return nil
    }
}

import Foundation
import QoderCore

@main
struct QoderRunCLI {
    static func main() async {
        do {
            let options = try CLIOptions.parse(CommandLine.arguments)
            if options.showHelp {
                printHelp()
                return
            }

            let prompt: String
            if let promptValue = options.prompt {
                prompt = promptValue
            } else if let promptFile = options.promptFile {
                prompt = try String(contentsOf: promptFile, encoding: .utf8)
            } else {
                throw CLIError.missingPrompt
            }

            let resolvedConfig = try QoderConfigResolver.resolve(
                configPath: options.configPath,
                profileName: options.profileName,
                overrides: QoderConfigOverrides(
                    baseURL: options.baseURL,
                    agentID: options.agentID,
                    agentVersion: options.agentVersion,
                    environmentID: options.environmentID,
                    outputRoot: options.outputRoot,
                    tokenEnv: options.tokenEnv
                )
            )
            var configuration = RunConfiguration(resolvedConfig: resolvedConfig)
            configuration.runID = options.runID
            configuration.runDirectory = options.runDirectory
            configuration.metadata = options.metadata
            let runner = QoderRunner(configuration: configuration)

            let result = try await runner.run(prompt: prompt)
            print("run_dir=\(result.runDirectory.path)")
            print("session_id=\(result.sessionID ?? "")")
            print("status=\(result.status)")
            print("report=\(result.reportURL.path)")
        } catch {
            fputs("error=\(error.localizedDescription)\n", stderr)
            if let runnerError = error as? QoderRunnerError, let runDirectory = runnerError.runDirectory {
                fputs("run_dir=\(runDirectory.path)\n", stderr)
            }
            Foundation.exit(1)
        }
    }

    private static func printHelp() {
        print("""
        Usage:
          qoder-run --prompt "your prompt"
          qoder-run --prompt-file /path/to/prompt.md

        Options:
          --agent ID             Qoder agent id
          --agent-version N      Qoder agent version to pin
          --environment-id ID    Qoder environment id
          --base-url URL         Qoder API base URL; defaults to qoder.com.cn
          --config PATH          config JSON path; defaults to config.local.json
          --profile NAME         profile name in config JSON
          --output-root PATH     output root for timestamped run folders
          --run-id ID            deterministic folder name under output root
          --run-dir PATH         exact output folder for this run
          --metadata K=V         session metadata; can be repeated
          --token-env NAME       token environment variable; defaults to QODER_PAT
          --help                 show this help
        """)
    }
}

private struct CLIOptions {
    var prompt: String?
    var promptFile: URL?
    var configPath: URL?
    var profileName: String?
    var baseURL: URL?
    var agentID: String?
    var agentVersion: Int?
    var environmentID: String?
    var outputRoot: URL?
    var runID: String?
    var runDirectory: URL?
    var metadata: [String: String] = [:]
    var tokenEnv: String?
    var showHelp = false

    static func parse(_ arguments: [String]) throws -> CLIOptions {
        var options = CLIOptions()
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                options.showHelp = true
            case "--prompt":
                options.prompt = try value(after: argument, in: arguments, index: &index)
            case "--prompt-file":
                options.promptFile = URL(fileURLWithPath: try value(after: argument, in: arguments, index: &index))
            case "--agent":
                options.agentID = try value(after: argument, in: arguments, index: &index)
            case "--agent-version":
                let rawValue = try value(after: argument, in: arguments, index: &index)
                guard let version = Int(rawValue), version > 0 else {
                    throw CLIError.invalidValue(argument, rawValue)
                }
                options.agentVersion = version
            case "--environment-id":
                options.environmentID = try value(after: argument, in: arguments, index: &index)
            case "--base-url":
                let rawValue = try value(after: argument, in: arguments, index: &index)
                guard let url = URL(string: rawValue), url.scheme != nil, url.host != nil else {
                    throw CLIError.invalidValue(argument, rawValue)
                }
                options.baseURL = url
            case "--config":
                options.configPath = URL(fileURLWithPath: try value(after: argument, in: arguments, index: &index))
            case "--profile":
                options.profileName = try value(after: argument, in: arguments, index: &index)
            case "--output-root":
                options.outputRoot = URL(fileURLWithPath: try value(after: argument, in: arguments, index: &index), isDirectory: true)
            case "--run-id":
                options.runID = try value(after: argument, in: arguments, index: &index)
            case "--run-dir":
                options.runDirectory = URL(fileURLWithPath: try value(after: argument, in: arguments, index: &index), isDirectory: true)
            case "--metadata":
                let rawValue = try value(after: argument, in: arguments, index: &index)
                let parts = rawValue.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, !parts[0].isEmpty else {
                    throw CLIError.invalidValue(argument, rawValue)
                }
                options.metadata[parts[0]] = parts[1]
            case "--token-env":
                options.tokenEnv = try value(after: argument, in: arguments, index: &index)
            default:
                throw CLIError.unknownArgument(argument)
            }
            index += 1
        }

        return options
    }

    private static func value(after option: String, in arguments: [String], index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw CLIError.missingValue(option)
        }
        index = valueIndex
        return arguments[valueIndex]
    }
}

private enum CLIError: LocalizedError {
    case missingPrompt
    case missingValue(String)
    case invalidValue(String, String)
    case unknownArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingPrompt:
            return "Missing --prompt or --prompt-file"
        case .missingValue(let option):
            return "Missing value for \(option)"
        case .invalidValue(let option, let value):
            return "Invalid value for \(option): \(value)"
        case .unknownArgument(let argument):
            return "Unknown argument: \(argument)"
        }
    }
}

import Foundation
import XCTest
@testable import QoderCore

final class QoderConfigTests: XCTestCase {
    func testResolverReadsTokenFromEnvFileNextToConfig() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        unsetenv("QODER_TEST_PAT_FILE_ONLY")

        let configURL = tempDir.appendingPathComponent("config.local.json")
        let envURL = tempDir.appendingPathComponent(".env")
        try configJSON(tokenEnv: "QODER_TEST_PAT_FILE_ONLY").write(to: configURL, atomically: true, encoding: .utf8)
        try "QODER_TEST_PAT_FILE_ONLY=from-env-file\n".write(to: envURL, atomically: true, encoding: .utf8)

        let resolved = try QoderConfigResolver.resolve(configPath: configURL)

        XCTAssertEqual(resolved.token, "from-env-file")
        XCTAssertEqual(resolved.envFile?.standardizedFileURL, envURL.standardizedFileURL)
        XCTAssertEqual(resolved.networkMode, .auto)
    }

    func testResolverReadsRelativeEnvFileFromConfig() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        unsetenv("QODER_TEST_PAT_RELATIVE")

        let secretsDir = tempDir.appendingPathComponent("secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: secretsDir, withIntermediateDirectories: true)
        let configURL = tempDir.appendingPathComponent("config.local.json")
        let envURL = secretsDir.appendingPathComponent("qoder.env")
        try configJSON(tokenEnv: "QODER_TEST_PAT_RELATIVE", envFile: "secrets/qoder.env")
            .write(to: configURL, atomically: true, encoding: .utf8)
        try "export QODER_TEST_PAT_RELATIVE='relative-env-file'\n".write(to: envURL, atomically: true, encoding: .utf8)

        let resolved = try QoderConfigResolver.resolve(configPath: configURL)

        XCTAssertEqual(resolved.token, "relative-env-file")
        XCTAssertEqual(resolved.envFile?.standardizedFileURL, envURL.standardizedFileURL)
    }

    func testResolverReadsNetworkModeFromConfig() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        unsetenv("QODER_TEST_PAT_NETWORK")

        let configURL = tempDir.appendingPathComponent("config.local.json")
        let envURL = tempDir.appendingPathComponent(".env")
        try configJSON(tokenEnv: "QODER_TEST_PAT_NETWORK", networkMode: "system")
            .write(to: configURL, atomically: true, encoding: .utf8)
        try "QODER_TEST_PAT_NETWORK=from-env-file\n".write(to: envURL, atomically: true, encoding: .utf8)

        let resolved = try QoderConfigResolver.resolve(configPath: configURL)

        XCTAssertEqual(resolved.networkMode, .system)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoder-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func configJSON(tokenEnv: String, envFile: String? = nil, networkMode: String? = nil) -> String {
        var fields = [
            #""base_url": "https://api.qoder.com.cn/api/v1/cloud""#,
            #""agent_id": "agent_test""#,
            #""environment_id": "env_test""#,
            #""output_root": "~/QoderRuns""#,
            #""token_env": "\#(tokenEnv)""#,
        ]
        if let envFile {
            fields.append(#""env_file": "\#(envFile)""#)
        }
        if let networkMode {
            fields.append(#""network_mode": "\#(networkMode)""#)
        }
        return """
        {
          "active_profile": "default",
          "profiles": {
            "default": {
              \(fields.joined(separator: ",\n      "))
            }
          }
        }
        """
    }
}

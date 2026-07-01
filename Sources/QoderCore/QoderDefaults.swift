import Foundation

public enum QoderDefaults {
    public static let apiBaseURL = URL(string: "https://api.qoder.com.cn/api/v1/cloud")!
    public static let localConfigFileName = "config.local.json"
    public static let exampleConfigFileName = "config.example.json"
    public static let defaultTokenEnvironmentVariable = "QODER_PAT"
    public static let defaultOutputRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("QoderRuns", isDirectory: true)
}

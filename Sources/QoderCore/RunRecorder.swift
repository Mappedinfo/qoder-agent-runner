import Foundation

public struct RunPaths {
    public let runDirectory: URL
    public let prompt: URL
    public let session: URL
    public let eventsSSE: URL
    public let eventsJSONL: URL
    public let report: URL
    public let metadata: URL
}

public final class RunRecorder {
    public let paths: RunPaths

    public init(outputRoot: URL, startedAt: Date = Date()) throws {
        let folderName = Self.timestampFormatter.string(from: startedAt)
        var runDirectory = outputRoot.appendingPathComponent(folderName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: runDirectory.path) {
            runDirectory = outputRoot.appendingPathComponent(String(format: "%@-%02d", folderName, suffix), isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)

        self.paths = RunPaths(
            runDirectory: runDirectory,
            prompt: runDirectory.appendingPathComponent("prompt.txt"),
            session: runDirectory.appendingPathComponent("session.json"),
            eventsSSE: runDirectory.appendingPathComponent("events.sse"),
            eventsJSONL: runDirectory.appendingPathComponent("events.jsonl"),
            report: runDirectory.appendingPathComponent("report.md"),
            metadata: runDirectory.appendingPathComponent("metadata.json")
        )

        FileManager.default.createFile(atPath: paths.eventsSSE.path, contents: nil)
        FileManager.default.createFile(atPath: paths.eventsJSONL.path, contents: nil)
    }

    public func writePrompt(_ prompt: String) throws {
        try write(prompt, to: paths.prompt)
    }

    public func writeSessionJSON(_ data: Data) throws {
        try writeJSONData(data, to: paths.session)
    }

    public func appendSSELine(_ line: String) throws {
        try append(line, to: paths.eventsSSE)
    }

    public func appendEventJSONLine(_ json: String) throws {
        try append(json + "\n", to: paths.eventsJSONL)
    }

    public func writeReport(_ report: String) throws {
        try write(report, to: paths.report)
    }

    public func writeMetadata(_ metadata: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: paths.metadata, options: .atomic)
    }

    public static func isoString(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private func append(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        let handle = try FileHandle(forWritingTo: url)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func writeJSONData(_ data: Data, to url: URL) throws {
        if
            let object = try? JSONSerialization.jsonObject(with: data),
            JSONSerialization.isValidJSONObject(object),
            let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        {
            try pretty.write(to: url, options: .atomic)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

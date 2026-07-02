import Foundation

public struct RunPaths {
    public let runDirectory: URL
    public let prompt: URL
    public let session: URL
    public let eventsSSE: URL
    public let eventsJSONL: URL
    public let artifactsDirectory: URL
    public let report: URL
    public let summary: URL
    public let metadata: URL
}

public final class RunRecorder {
    public let paths: RunPaths

    public init(
        outputRoot: URL,
        startedAt: Date = Date(),
        runID: String? = nil,
        runDirectory explicitRunDirectory: URL? = nil
    ) throws {
        let runDirectory: URL
        if let explicitRunDirectory {
            runDirectory = explicitRunDirectory
        } else if let runID, !runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runDirectory = outputRoot.appendingPathComponent(Self.safeRunFolderName(runID), isDirectory: true)
        } else {
            let folderName = Self.timestampFormatter.string(from: startedAt)
            var timestampedDirectory = outputRoot.appendingPathComponent(folderName, isDirectory: true)
            var suffix = 2
            while FileManager.default.fileExists(atPath: timestampedDirectory.path) {
                timestampedDirectory = outputRoot.appendingPathComponent(String(format: "%@-%02d", folderName, suffix), isDirectory: true)
                suffix += 1
            }
            runDirectory = timestampedDirectory
        }
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)

        self.paths = RunPaths(
            runDirectory: runDirectory,
            prompt: runDirectory.appendingPathComponent("prompt.txt"),
            session: runDirectory.appendingPathComponent("session.json"),
            eventsSSE: runDirectory.appendingPathComponent("events.sse"),
            eventsJSONL: runDirectory.appendingPathComponent("events.jsonl"),
            artifactsDirectory: runDirectory.appendingPathComponent("artifacts", isDirectory: true),
            report: runDirectory.appendingPathComponent("report.md"),
            summary: runDirectory.appendingPathComponent("summary.md"),
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

    public func writeSummary(_ summary: String) throws {
        try write(summary, to: paths.summary)
    }

    public func writeArtifact(originalPath: String?, content: String) throws -> URL {
        try FileManager.default.createDirectory(at: paths.artifactsDirectory, withIntermediateDirectories: true)

        let filename = Self.safeArtifactFilename(from: originalPath)
        let baseURL = paths.artifactsDirectory.appendingPathComponent(filename)
        let targetURL = uniqueURL(for: baseURL)
        try write(content, to: targetURL)
        return targetURL
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

    private func uniqueURL(for url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return url
        }

        let directory = url.deletingLastPathComponent()
        let basename = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var suffix = 2

        while true {
            let filename = ext.isEmpty
                ? String(format: "%@-%02d", basename, suffix)
                : String(format: "%@-%02d.%@", basename, suffix, ext)
            let candidate = directory.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    private static func safeArtifactFilename(from originalPath: String?) -> String {
        let fallback = "artifact.md"
        guard let originalPath, !originalPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }

        let filename = URL(fileURLWithPath: originalPath).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filename.isEmpty, filename != ".", filename != "/" else {
            return fallback
        }

        let cleaned = filename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")

        return cleaned.isEmpty ? fallback : cleaned
    }

    private static func safeRunFolderName(_ runID: String) -> String {
        let cleaned = runID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty ? timestampFormatter.string(from: Date()) : cleaned
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

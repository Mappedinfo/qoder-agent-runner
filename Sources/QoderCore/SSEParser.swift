import Foundation

public struct SSEEvent: Equatable {
    public let id: String?
    public let event: String?
    public let data: String?
    public let raw: String

    public var name: String {
        event ?? "message"
    }
}

public struct SSEParser {
    private var id: String?
    private var event: String?
    private var dataLines: [String] = []
    private var rawLines: [String] = []

    public init() {}

    public mutating func consume(line: String) -> SSEEvent? {
        if beginsNewEvent(line), hasPendingEvent {
            let pending = flush()
            consumeFieldLine(line)
            return pending
        }

        if line.isEmpty {
            rawLines.append(line)
            return flush()
        }

        if line.hasPrefix(":") {
            rawLines.append(line)
            return nil
        }

        consumeFieldLine(line)
        if line.hasPrefix("data:") {
            return flush()
        }
        return nil
    }

    public mutating func finish() -> SSEEvent? {
        flush()
    }

    private var hasPendingEvent: Bool {
        id != nil || event != nil || !dataLines.isEmpty
    }

    private func beginsNewEvent(_ line: String) -> Bool {
        line.hasPrefix("id:")
    }

    private mutating func consumeFieldLine(_ line: String) {
        rawLines.append(line)

        let field: String
        let value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            var parsedValue = String(line[line.index(after: colon)...])
            if parsedValue.hasPrefix(" ") {
                parsedValue.removeFirst()
            }
            value = parsedValue
        } else {
            field = line
            value = ""
        }

        switch field {
        case "id":
            id = value
        case "event":
            event = value
        case "data":
            dataLines.append(value)
        default:
            break
        }
    }

    private mutating func flush() -> SSEEvent? {
        defer {
            id = nil
            event = nil
            dataLines.removeAll()
            rawLines.removeAll()
        }

        guard id != nil || event != nil || !dataLines.isEmpty else {
            return nil
        }

        let data = dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
        return SSEEvent(
            id: id,
            event: event,
            data: data,
            raw: rawLines.joined(separator: "\n") + "\n"
        )
    }
}

import Foundation

/// A single Server-Sent Events frame.
struct SSEEvent: Equatable, Sendable {
    var event: String
    var id: String
    var data: String
    var retry: Int?

    init(event: String = "", id: String = "", data: String = "", retry: Int? = nil) {
        self.event = event
        self.id = id
        self.data = data
        self.retry = retry
    }
}

/// Incremental parser for the `text/event-stream` wire format.
///
/// Chunks may split frames or even UTF-8 sequences at arbitrary byte
/// boundaries; the parser only decodes complete lines and keeps the rest
/// buffered until more bytes arrive. A frame is emitted when a blank line
/// terminates it, matching the SSE specification.
struct SSEParser {
    private var buffer = Data()
    private var eventType = ""
    private var dataBuffer = ""
    private var lastEventID = ""
    private var retryInterval: Int?

    mutating func feed(_ chunk: Data) -> [SSEEvent] {
        buffer.append(chunk)
        var events: [SSEEvent] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)

            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") {
                line.removeLast()
            }

            if line.isEmpty {
                if let event = dispatch() {
                    events.append(event)
                }
                continue
            }

            // Lines starting with ":" are comments (used as keep-alives).
            if line.hasPrefix(":") {
                continue
            }

            let field: String
            var value: String
            if let colon = line.firstIndex(of: ":") {
                field = String(line[line.startIndex..<colon])
                value = String(line[line.index(after: colon)...])
                if value.hasPrefix(" ") {
                    value.removeFirst()
                }
            } else {
                field = line
                value = ""
            }

            switch field {
            case "event":
                eventType = value
            case "data":
                dataBuffer += value + "\n"
            case "id":
                if !value.contains("\0") {
                    lastEventID = value
                }
            case "retry":
                if let parsed = Int(value) {
                    retryInterval = parsed
                }
            default:
                break
            }
        }

        return events
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            eventType = ""
            dataBuffer = ""
        }

        guard !dataBuffer.isEmpty else {
            return nil
        }
        if dataBuffer.hasSuffix("\n") {
            dataBuffer.removeLast()
        }

        return SSEEvent(event: eventType, id: lastEventID, data: dataBuffer, retry: retryInterval)
    }
}

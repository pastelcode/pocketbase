import Foundation

/// A single Server-Sent Events frame.
struct SSEEvent: Equatable, Sendable {
    /// The event type from the `event:` field, empty when unspecified.
    var event: String
    /// The last event identifier seen in an `id:` field.
    var id: String
    /// The payload joined from one or more `data:` fields.
    var data: String
    /// The reconnection time from a `retry:` field, in milliseconds.
    var retry: Int?

    /// Creates an event frame.
    ///
    /// - Parameter event: The event type.
    /// - Parameter id: The last event identifier.
    /// - Parameter data: The event payload.
    /// - Parameter retry: The server-suggested reconnection delay in milliseconds.
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
    /// Bytes received but not yet terminated by a newline.
    private var buffer = Data()
    /// The event type accumulated for the current frame.
    private var eventType = ""
    /// The data lines accumulated for the current frame.
    private var dataBuffer = ""
    /// The most recent event identifier, reused across frames.
    private var lastEventID = ""
    /// The most recent server-suggested retry interval in milliseconds.
    private var retryInterval: Int?

    /// Appends a chunk of bytes and returns the frames completed by it.
    ///
    /// Partial lines and split UTF-8 sequences stay buffered until more data
    /// arrives.
    ///
    /// - Parameter chunk: The newly received bytes.
    /// - Returns: The frames completed by this chunk, in order.
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

    /// Finalizes the current frame and resets the per-frame accumulators.
    ///
    /// - Returns: The completed frame, or `nil` when no data was accumulated.
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

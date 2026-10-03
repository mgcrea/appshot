import Foundation

/// One cue, as appshot appends it to the cue file at its scheduled time.
public struct CueLine: Codable, Sendable, Equatable {
    public var seq: Int
    public var t: Double
    public var cue: String
    public var args: [String: Config.CueValue]

    public init(seq: Int, t: Double, cue: String, args: [String: Config.CueValue]) {
        self.seq = seq
        self.t = t
        self.cue = cue
        self.args = args
    }
}

/// One line the app appends to the event file.
///
/// `kind` stays a string: an app on a newer contract may send kinds this appshot does
/// not know, and the recorder decides what an unknown kind means, not the decoder.
public struct AppEvent: Codable, Sendable, Equatable {
    /// `ready`, `ack`, `target` or `unknown`.
    public var kind: String
    public var seq: Int?
    public var name: String?
    /// Global screen points, top-left origin.
    public var rect: [Double]?
    public var cue: String?
}

public enum CuePolicy {
    public static let warnLatency = 0.05
    public static let failLatency = 0.25
    public static let ackTimeout = 1.0
}

/// The two JSON-lines files appshot and the app talk through.
///
/// Files, not a socket or a notification: the ready file already proved that this is
/// the one channel that crosses the Mac sandbox and the simulator alike.
public final class CueChannel {
    public let cueFile: URL
    public let eventFile: URL
    private var offset: UInt64 = 0
    private var partial = Data()

    public init(directory: URL) throws {
        let id = UUID().uuidString
        cueFile = directory.appending(path: "appshot-cues-\(id).jsonl")
        eventFile = directory.appending(path: "appshot-events-\(id).jsonl")
        // Both exist before launch: the app opens the cue file to watch it, and a
        // sandboxed app can append to an existing file in its container.
        guard FileManager.default.createFile(atPath: cueFile.path, contents: nil),
            FileManager.default.createFile(atPath: eventFile.path, contents: nil)
        else {
            throw AppShotError.recordFailed(
                video: "", reason: "cannot create the cue files in \(directory.path)")
        }
    }

    public func send(_ line: CueLine) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let handle = try FileHandle(forWritingTo: cueFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: try encoder.encode(line) + Data("\n".utf8))
    }

    /// New complete lines since the last poll. A line still being written stays
    /// buffered until its newline arrives.
    public func poll() throws -> [AppEvent] {
        let handle = try FileHandle(forReadingFrom: eventFile)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        offset += UInt64(data.count)
        partial += data

        var events: [AppEvent] = []
        while let newline = partial.firstIndex(of: UInt8(ascii: "\n")) {
            let line = partial[partial.startIndex..<newline]
            partial = Data(partial[partial.index(after: newline)...])
            guard !line.isEmpty else { continue }
            do {
                events.append(try JSONDecoder().decode(AppEvent.self, from: Data(line)))
            } catch {
                let message = String(decoding: line, as: UTF8.self)
                throw AppShotError.recordFailed(
                    video: "", reason: "the app wrote a line that is not an event: \(message)")
            }
        }
        return events
    }

    public func remove() {
        try? FileManager.default.removeItem(at: cueFile)
        try? FileManager.default.removeItem(at: eventFile)
    }
}

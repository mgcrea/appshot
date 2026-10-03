import Foundation
import Testing

@testable import AppShotKit

struct CueChannelTests {
    static func channel() throws -> CueChannel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "cue-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try CueChannel(directory: dir)
    }

    @Test func sendAppendsOneJSONLinePerCue() throws {
        let channel = try Self.channel()
        try channel.send(CueLine(seq: 0, t: 1.5, cue: "pointer.click", args: ["target": .string("row-2")]))
        try channel.send(CueLine(seq: 1, t: 3, cue: "stage", args: ["to": .string("codex")]))
        let lines = try String(contentsOf: channel.cueFile, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let first = try JSONDecoder().decode(CueLine.self, from: Data(lines[0].utf8))
        #expect(first.cue == "pointer.click")
    }

    @Test func pollReturnsOnlyCompleteNewLines() throws {
        let channel = try Self.channel()
        let handle = try FileHandle(forWritingTo: channel.eventFile)
        handle.write(Data(#"{"kind":"ready"}"#.utf8) + Data("\n".utf8) + Data(#"{"kind":"ack","se"#.utf8))
        #expect(try channel.poll() == [AppEvent(kind: "ready", seq: nil, name: nil, rect: nil, cue: nil)])
        #expect(try channel.poll().isEmpty)
        handle.write(Data(#"q":3}"#.utf8) + Data("\n".utf8))
        #expect(try channel.poll().map(\.seq) == [3])
        try handle.close()
    }

    @Test func garbageLineIsAnError() throws {
        let channel = try Self.channel()
        try Data("not json\n".utf8).write(to: channel.eventFile)
        #expect(throws: AppShotError.self) { try channel.poll() }
    }

    @Test func handshakeDirectoryFallsBackToTmpForUnsandboxedApps() {
        let dir = Capture.handshakeDirectory(for: URL(fileURLWithPath: "/nonexistent/Nope.app"))
        #expect(dir.path == URL(fileURLWithPath: NSTemporaryDirectory()).path)
    }
}

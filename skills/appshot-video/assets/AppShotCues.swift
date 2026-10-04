import AppKit

/// The app's half of `appshot record`'s cue contract, as one file to drop into a demo
/// seed. The app writes only `perform`: what each cue means for *its* state.
///
/// appshot launches the app with `-ScreenshotCueFile <path>` and
/// `-ScreenshotEventFile <path>` (both files already exist, in the app's container when
/// it is sandboxed). This class watches the first and appends to the second:
///
///     {"kind":"ready"}                                    once, when you call ready()
///     {"kind":"target","seq":n,"name":…,"rect":[x,y,w,h]} for a .target outcome
///     {"kind":"ack","seq":n}                              one runloop turn after the effect
///     {"kind":"unknown","seq":n,"cue":…}                  for a cue this app doesn't do
///
/// Usage, from wherever screenshot mode stages its first screen:
///
///     cues = AppShotCues.start { cue in
///         switch cue.name {
///         case "stage": model.stage = cue.string("to"); return .done
///         case "pointer.click":
///             guard let rect = model.frame(of: cue.string("target")) else { return .unknown }
///             model.select(cue.string("target"))
///             return .target(name: cue.string("target") ?? "", rect: rect)
///         default: return .unknown
///         }
///     }
///     cues?.ready()   // after the first screen is fully on screen
///
/// Keep the returned object alive for the life of the process.
@MainActor
final class AppShotCues {
    struct Cue {
        let seq: Int
        let name: String
        let args: [String: Any]

        func string(_ key: String) -> String? { args[key] as? String }
        func number(_ key: String) -> Double? { (args[key] as? NSNumber)?.doubleValue }
        func bool(_ key: String) -> Bool? { args[key] as? Bool }
    }

    enum Outcome {
        /// The effect is applied; acknowledge it.
        case done
        /// A pointer cue: report where the element is, then acknowledge. `rect` is in
        /// global screen points with a top-left origin; `AppShotCues.screenRect(of:)`
        /// converts a view or a rect inside one.
        case target(name: String, rect: CGRect)
        /// Not implemented here. appshot fails the take naming the cue, which is the
        /// point: a cue that silently does nothing records a video that lies.
        case unknown
    }

    private let cueFile: String
    private let eventFile: String
    private let perform: (Cue) -> Outcome
    private var offset: UInt64 = 0
    private var buffer = Data()
    private var timer: Timer?

    /// Nil unless appshot launched the app to record: no file is watched otherwise.
    static func start(perform: @escaping (Cue) -> Outcome) -> AppShotCues? {
        let defaults = UserDefaults.standard
        guard let cueFile = defaults.string(forKey: "ScreenshotCueFile"),
            let eventFile = defaults.string(forKey: "ScreenshotEventFile")
        else { return nil }
        let cues = AppShotCues(cueFile: cueFile, eventFile: eventFile, perform: perform)
        // 10ms polling: a file read costs microseconds, and the recorder's budget for a
        // cue's ack is 50ms before it warns and 250ms before it fails the take.
        cues.timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated { cues.poll() }
        }
        return cues
    }

    private init(cueFile: String, eventFile: String, perform: @escaping (Cue) -> Outcome) {
        self.cueFile = cueFile
        self.eventFile = eventFile
        self.perform = perform
    }

    /// Call once the first screen is staged and drawn: t = 0 of the video is the first
    /// frame recorded after this, so anything still loading shows up in the take.
    func ready() {
        DispatchQueue.main.async { self.emit(["kind": "ready"]) }
    }

    /// Complete lines only. appshot appends each cue in one write, but a read can still
    /// land mid-line, so the tail waits in `buffer` for its newline.
    nonisolated static func cues(from buffer: inout Data) -> [Cue] {
        var cues: [Cue] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let seq = object["seq"] as? Int, let name = object["cue"] as? String
            else { continue }
            cues.append(Cue(seq: seq, name: name, args: object["args"] as? [String: Any] ?? [:]))
        }
        return cues
    }

    /// A view's bounds (or a rect inside it) in global screen points, top-left origin:
    /// the CGWindowList convention appshot maps onto the recording.
    static func screenRect(of view: NSView, rect: NSRect? = nil) -> CGRect? {
        guard let window = view.window else { return nil }
        let inWindow = view.convert(rect ?? view.bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        // Flip against the primary display, whichever screen the window is on.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(
            x: onScreen.minX, y: primaryTop - onScreen.maxY, width: onScreen.width, height: onScreen.height)
    }

    private func poll() {
        guard let file = FileHandle(forReadingAtPath: cueFile) else { return }
        defer { try? file.close() }
        try? file.seek(toOffset: offset)
        let data = (try? file.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        buffer += data
        for cue in Self.cues(from: &buffer) { run(cue) }
    }

    private func run(_ cue: Cue) {
        switch perform(cue) {
        case .unknown:
            emit(["kind": "unknown", "seq": cue.seq, "cue": cue.name])
            return
        case .target(let name, let rect):
            emit([
                "kind": "target", "seq": cue.seq, "name": name,
                "rect": [rect.minX, rect.minY, rect.width, rect.height],
            ])
        case .done:
            break
        }
        // Draw now, acknowledge on the next turn: an ack written before the frame
        // commits tells the recorder the effect is on screen when it is not, and the
        // caption or focus keyed to it lands early.
        for window in NSApp.windows where window.isVisible { window.displayIfNeeded() }
        DispatchQueue.main.async { self.emit(["kind": "ack", "seq": cue.seq]) }
    }

    private func emit(_ event: [String: Any]) {
        guard let handle = FileHandle(forWritingAtPath: eventFile),
            let data = try? JSONSerialization.data(withJSONObject: event)
        else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }
}

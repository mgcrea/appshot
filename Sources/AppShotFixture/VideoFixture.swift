import AppKit

/// The `video` stage: an app that speaks the cue contract the way a real app's demo
/// seed would, so `appshot record` can be exercised without borrowing a product.
///
/// Every effect is acknowledged one runloop turn *after* it is drawn, as the contract
/// asks: an ack written before the frame commits is an ack that lies.
@MainActor
final class VideoFixture: NSObject, NSApplicationDelegate {
    final class RowsView: NSView {
        var highlighted: Int?
        var flashed = false
        var alt = false
        override var isFlipped: Bool { true }

        func rowRect(_ i: Int) -> NSRect {
            NSRect(x: 32, y: 104 + Double(i) * 64, width: bounds.width - 64, height: 48)
        }

        override func draw(_ dirty: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            (flashed ? NSColor.systemOrange : NSColor.systemBlue).setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 72).fill()
            for i in 0..<6 {
                (highlighted == i ? NSColor.systemGreen : NSColor.tertiaryLabelColor).setFill()
                NSBezierPath(roundedRect: rowRect(i), xRadius: 8, yRadius: 8).fill()
                let label = (alt ? "Alt row \(i)" : "Row \(i)") as NSString
                label.draw(
                    at: NSPoint(x: rowRect(i).minX + 16, y: rowRect(i).minY + 14),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.labelColor,
                    ])
            }
        }
    }

    let cueFile: String?
    let eventFile: String?
    var window: NSWindow?
    /// Windows opened by cues, kept alive for the take.
    var windows: [NSWindow] = []
    let view = RowsView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    var offset: UInt64 = 0
    var buffer = Data()

    init(cueFile: String?, eventFile: String?) {
        self.cueFile = cueFile
        self.eventFile = eventFile
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "appshot fixture — video"
        window.contentView = view
        // A fixed place, as a demo seed pins its windows, so takes are comparable.
        window.setFrameTopLeftPoint(NSPoint(x: 200, y: (NSScreen.main?.frame.maxY ?? 1000) - 160))
        // Never orderFrontRegardless(): under --no-activate that puts the window over the
        // person's own app, which `capture` fails as raised_above_front_app. A background
        // window records anyway, since ScreenCaptureKit captures occluded windows.
        window.makeKeyAndOrderFront(nil)
        self.window = window
        if UserDefaults.standard.string(forKey: "ScreenshotActivation") != "none" {
            NSApp.activate(ignoringOtherApps: true)
        }
        DispatchQueue.main.async { self.emit(["kind": "ready"]) }
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated { self.readCues() }
        }
    }

    func readCues() {
        guard let cueFile, let file = FileHandle(forReadingAtPath: cueFile) else { return }
        defer { try? file.close() }
        try? file.seek(toOffset: offset)
        let data = (try? file.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        buffer += data
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            guard let cue = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let seq = cue["seq"] as? Int, let name = cue["cue"] as? String
            else { continue }
            handle(seq: seq, cue: name, args: cue["args"] as? [String: Any] ?? [:])
        }
    }

    func handle(seq: Int, cue: String, args: [String: Any]) {
        switch cue {
        case "pointer.move", "pointer.click":
            guard let target = args["target"] as? String, target.hasPrefix("row-"),
                let i = Int(target.dropFirst(4)), (0..<6).contains(i), let window
            else { return emit(["kind": "unknown", "seq": seq, "cue": cue]) }
            // Global screen points, top-left origin: the CGWindowList convention appshot uses.
            let inWindow = view.convert(view.rowRect(i), to: nil)
            let onScreen = window.convertToScreen(inWindow)
            let top = (NSScreen.screens.first?.frame.maxY ?? 0) - onScreen.maxY
            emit([
                "kind": "target", "seq": seq, "name": target,
                "rect": [onScreen.minX, top, onScreen.width, onScreen.height],
            ])
            if cue == "pointer.click" { view.highlighted = i }
        case "stage":
            view.alt = (args["to"] as? String) == "alt"
        case "fixture.flash":
            view.flashed.toggle()
        case "fixture.window":
            guard let window else { return emit(["kind": "unknown", "seq": seq, "cue": cue]) }
            let second = openSecondWindow(beside: window)
            // Reported like a pointer target, so a zoom can name it and a test can find it.
            let onScreen = second.convertToScreen(second.contentLayoutRect)
            let top = (NSScreen.screens.first?.frame.maxY ?? 0) - onScreen.maxY
            emit([
                "kind": "target", "seq": seq, "name": "window-2",
                "rect": [onScreen.minX, top, onScreen.width, onScreen.height],
            ])
            DispatchQueue.main.async { self.emit(["kind": "ack", "seq": seq]) }
            return
        default:
            return emit(["kind": "unknown", "seq": seq, "cue": cue])
        }
        view.needsDisplay = true
        view.displayIfNeeded()
        DispatchQueue.main.async { self.emit(["kind": "ack", "seq": seq]) }
    }

    /// A second window opened mid-take, which must join the recording. Beside the first
    /// rather than over it, so its pixels can only come from the window itself.
    func openSecondWindow(beside first: NSWindow) -> NSWindow {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 240))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.systemPurple.cgColor
        let second = NSWindow(
            contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        second.title = "appshot fixture — second window"
        second.contentView = content
        let visible = first.screen?.visibleFrame ?? .zero
        var origin = NSPoint(x: first.frame.maxX + 24, y: first.frame.maxY - second.frame.height)
        if origin.x + second.frame.width > visible.maxX {
            origin.x = first.frame.minX - 24 - second.frame.width
        }
        second.setFrameOrigin(origin)
        second.makeKeyAndOrderFront(nil)
        second.displayIfNeeded()
        windows.append(second)
        return second
    }

    func emit(_ event: [String: Any]) {
        guard let eventFile, let handle = FileHandle(forWritingAtPath: eventFile),
            let data = try? JSONSerialization.data(withJSONObject: event)
        else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }
}

// Ask macOS for the icon it actually composes for a bundle, at full resolution.
//
// This matters because the file on disk is not what the user sees: from macOS 26 the system
// masks every icon to its own squircle, scales it, and draws the shadow itself. Reading the
// .appiconset PNG or the .icns tells you what you authored, not what renders — and on modern
// apps the .icns is only a 256px fallback anyway.
//
//   swiftc -O render-icon.swift -o /tmp/render-icon
//   /tmp/render-icon /Applications/Yours.app /System/Applications/Notes.app
//
// Writes rendered_<AppName>.png into the working directory. Pass peers you consider well-drawn
// in the same run — every judgement about icon size is comparative.
//
// Caveat: NSWorkspace returns a *generic* icon for bundles LaunchServices will not resolve
// (unsigned stubs, odd locations). A non-square result means you measured the generic document
// icon. Re-register a real bundle with:
//   /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f <App>.app

import AppKit

let paths = Array(CommandLine.arguments.dropFirst())
guard !paths.isEmpty else {
    FileHandle.standardError.write("usage: render-icon <App.app> [more.app …]\n".data(using: .utf8)!)
    exit(2)
}

let side = 1024

for path in paths {
    guard FileManager.default.fileExists(atPath: path) else {
        print("skip (no such bundle): \(path)")
        continue
    }
    let image = NSWorkspace.shared.icon(forFile: path)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        print("skip (could not allocate bitmap): \(path)")
        continue
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()

    let name = (path as NSString).lastPathComponent
        .replacingOccurrences(of: ".app", with: "")
        .replacingOccurrences(of: " ", with: "_")
    let out = "rendered_\(name).png"
    if let data = rep.representation(using: .png, properties: [:]) {
        do {
            try data.write(to: URL(fileURLWithPath: out))
            print("wrote \(out)")
        } catch {
            print("skip (write failed): \(out) — \(error.localizedDescription)")
        }
    }
}

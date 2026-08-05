import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// The icon set is the one output whose breakage costs a full archive-export-upload
/// round trip to discover, because Xcode builds a hollow `.appiconset` without
/// complaint and App Store Connect only objects at upload (error 90236). These pin
/// the two things that matter: every slot exists at its exact pixel size, and the
/// audit actually notices when one does not.
struct IconTests {
    // MARK: - Helpers

    static func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-icon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A trivial two-colour mark. SVG rather than PNG on purpose: vector input is the
    /// case that has no `CGImageSource` support at all and goes through `NSImage`.
    static func writeMark(in dir: URL) throws -> URL {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
              <rect x="0" y="0" width="4" height="10" fill="#ff0000"/>
              <rect x="6" y="2" width="4" height="6" fill="#00ff00"/>
            </svg>
            """
        let url = dir.appending(path: "mark.svg")
        try svg.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (
        r: UInt8, g: UInt8, b: UInt8, a: UInt8
    ) {
        let px = Image.pixels(image)!
        return px[y * px.width + x]
    }

    // MARK: - Slots

    @Test func macSlotsCoverEveryRequiredSize() {
        let slots = Icon.macSlots
        #expect(slots.count == 10)
        // 512@2x is the one whose absence produces error 90236, so it is named here
        // rather than left implied by the count.
        #expect(slots.contains(Icon.Slot(points: 512, scale: 2)))
        #expect(slots.first { $0.points == 512 && $0.scale == 2 }?.pixels == 1024)
        #expect(Set(slots.map(\.pixels)) == [16, 32, 64, 128, 256, 512, 1024])
    }

    /// Xcode drops a slot whose filename does not match what `Contents.json` says,
    /// silently, so the naming is part of the contract rather than cosmetic.
    @Test func filenamesFollowXcodeConvention() {
        #expect(Icon.Slot(points: 16, scale: 1).filename == "icon_16x16.png")
        #expect(Icon.Slot(points: 512, scale: 2).filename == "icon_512x512@2x.png")
    }

    @Test func contentsJSONDeclaresEverySlot() throws {
        let json = Icon.contentsJSON(for: Icon.macSlots)
        let root =
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let images = root["images"] as! [[String: Any]]
        #expect(images.count == Icon.macSlots.count)
        for slot in Icon.macSlots {
            #expect(images.contains { $0["filename"] as? String == slot.filename })
        }
    }

    // MARK: - Generating

    @Test func generateWritesEverySlotAtItsExactSize() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)
        let out = dir.appending(path: "AppIcon.appiconset")

        let written = try Icon.generate(
            mark: mark, into: out, options: Icon.Options(plate: .solid("#101010")))

        #expect(written.count == Icon.macSlots.count)
        for slot in Icon.macSlots {
            let size = Image.size(out.appending(path: slot.filename))
            #expect(size?.width == slot.pixels)
            #expect(size?.height == slot.pixels)
        }
        #expect(try Icon.audit(out).isEmpty)
    }

    /// The plate has to sit on Apple's grid, not fill the canvas: a full-bleed macOS
    /// icon renders visibly larger than every neighbour in the Dock.
    @Test func plateLeavesTheMacOSMargin() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)

        let image = try Icon.render(
            mark: mark, pixels: 1024, options: Icon.Options(plate: .solid("#101010")))

        // Just outside the 824-wide plate: transparent.
        #expect(Self.pixel(image, 20, 512).a == 0)
        // Just inside it: opaque plate.
        #expect(Self.pixel(image, 120, 512).a == 255)
    }

    /// A mark authored with `currentColor` renders black on its own, so recolouring
    /// has to go through the shape as a mask rather than through its pixels.
    @Test func tintRecoloursTheMarkThroughItsAlpha() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
              <rect x="0" y="0" width="10" height="10" fill="currentColor"/>
            </svg>
            """
        let mark = dir.appending(path: "mono.svg")
        try svg.write(to: mark, atomically: true, encoding: .utf8)

        let plain = try Icon.render(mark: mark, pixels: 256, options: Icon.Options())
        let tinted = try Icon.render(
            mark: mark, pixels: 256, options: Icon.Options(tint: "#ff0000"))

        // The mark fills the centre in both; only its colour should differ.
        #expect(Self.pixel(plain, 128, 128).r < 40)
        let t = Self.pixel(tinted, 128, 128)
        #expect(t.r > 200)
        #expect(t.g < 40)
    }

    // MARK: - Gradient plate

    @Test func gradientPlateSpacesStopsEvenly() throws {
        guard case .gradient(let bg) = try Icon.gradientPlate(
            hexes: ["#000000", "#888888", "#ffffff"], angle: 45)
        else { return #expect(Bool(false), "expected a gradient plate") }

        #expect(bg.angle == 45)
        #expect(bg.stops.map(\.offset) == [0, 0.5, 1])
    }

    @Test func gradientPlateRejectsBadInput() {
        #expect(throws: AppShotError.self) {
            _ = try Icon.gradientPlate(hexes: ["#000000"], angle: 0)
        }
        #expect(throws: AppShotError.self) {
            _ = try Icon.gradientPlate(hexes: ["#000000", "not-a-colour"], angle: 0)
        }
    }

    @Test func solidPlateRejectsBadHex() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)
        #expect(throws: AppShotError.self) {
            _ = try Icon.render(
                mark: mark, pixels: 64, options: Icon.Options(plate: .solid("nope")))
        }
    }

    // MARK: - Audit

    /// The exact shape that cost an upload, transcribed from the real file: every
    /// slot declared by size and scale, none carrying a `filename`. It builds, it
    /// runs, it shows a blank icon, and only App Store Connect objects.
    ///
    /// One finding per slot, not two — the earlier filename-keyed audit reported
    /// each slot as both undeclared and missing, which reads as twenty problems
    /// where there are ten.
    @Test func auditCatchesXcodesHollowIconSet() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appending(path: "AppIcon.appiconset")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let entries = Icon.macSlots.map {
            """
              { "idiom" : "mac", "scale" : "\($0.scale)x", "size" : "\($0.points)x\($0.points)" }
            """
        }
        try "{ \"images\" : [\n\(entries.joined(separator: ",\n"))\n] }"
            .write(to: out.appending(path: "Contents.json"), atomically: true, encoding: .utf8)

        let findings = try Icon.audit(out)
        #expect(findings.count == Icon.macSlots.count)
        #expect(findings.allSatisfy { if case .emptySlot = $0.kind { true } else { false } })
        #expect(findings.contains { $0.kind == .emptySlot("512x512@2x") })
    }

    /// A set declaring nothing at all: every slot is undeclared, once each.
    @Test func auditCatchesAnEmptyContentsJSON() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appending(path: "AppIcon.appiconset")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try "{ \"images\" : [] }"
            .write(to: out.appending(path: "Contents.json"), atomically: true, encoding: .utf8)

        let findings = try Icon.audit(out)
        #expect(findings.count == Icon.macSlots.count)
        #expect(findings.allSatisfy { if case .notDeclared = $0.kind { true } else { false } })
    }

    /// A project free to name its images whatever it likes: the audit has to follow
    /// `Contents.json`, not assume Xcode's default filenames.
    @Test func auditFollowsDeclaredFilenames() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)
        let out = dir.appending(path: "AppIcon.appiconset")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let entries = try Icon.macSlots.map { slot -> String in
            let name = "custom-\(slot.pixels).png"
            try Image.write(
                Icon.render(mark: mark, pixels: slot.pixels, options: Icon.Options()),
                to: out.appending(path: name))
            return """
                  { "filename" : "\(name)", "idiom" : "mac", \
                "scale" : "\(slot.scale)x", "size" : "\(slot.points)x\(slot.points)" }
                """
        }
        try "{ \"images\" : [\n\(entries.joined(separator: ",\n"))\n] }"
            .write(to: out.appending(path: "Contents.json"), atomically: true, encoding: .utf8)

        #expect(try Icon.audit(out).isEmpty)
    }

    @Test func auditCatchesAWrongSizedImage() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)
        let out = dir.appending(path: "AppIcon.appiconset")
        _ = try Icon.generate(mark: mark, into: out)

        // Overwrite one slot with a plausible-looking but wrong-sized image.
        let wrong = try Icon.render(mark: mark, pixels: 64, options: Icon.Options())
        try Image.write(wrong, to: out.appending(path: "icon_512x512@2x.png"))

        let findings = try Icon.audit(out)
        #expect(findings.count == 1)
        #expect(
            findings.first?.kind
                == .wrongSize("icon_512x512@2x.png", got: "64x64", want: "1024x1024"))
    }

    /// A directory with the images but no `Contents.json` is the other half: Xcode
    /// reads the manifest, so undeclared files are invisible to the build.
    @Test func auditCatchesAMissingContentsJSON() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)
        let out = dir.appending(path: "AppIcon.appiconset")
        _ = try Icon.generate(mark: mark, into: out)
        try FileManager.default.removeItem(at: out.appending(path: "Contents.json"))

        let findings = try Icon.audit(out)
        #expect(findings.count == Icon.macSlots.count)
        #expect(findings.allSatisfy { if case .notDeclared = $0.kind { true } else { false } })
    }

    /// The trap that got past the first version of this audit, on a real repo:
    /// `Assets.xcassets/**/*.png` in `.gitattributes`, a clone without `git lfs pull`,
    /// and every slot holding a 130-byte text pointer named `.png`. `Image.size`
    /// returns nil for those, so an `if let` treated them as fine and the audit
    /// blessed an icon set that builds to a blank icon.
    @Test func auditCatchesGitLFSPointers() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)
        let out = dir.appending(path: "AppIcon.appiconset")
        _ = try Icon.generate(mark: mark, into: out)

        let pointer = """
            version https://git-lfs.github.com/spec/v1
            oid sha256:e50af6c578579de508779fb3840e0cc7ebe1b076a0fdc12573cf779077961d94
            size 24729

            """
        try pointer.write(
            to: out.appending(path: "icon_512x512@2x.png"), atomically: true, encoding: .utf8)

        let findings = try Icon.audit(out)
        #expect(findings.count == 1)
        #expect(findings.first?.kind == .gitLFSPointer("icon_512x512@2x.png"))
    }

    /// Anything else undecodable is a finding too, rather than a silently skipped slot.
    @Test func auditCatchesAnUnreadableImage() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)
        let out = dir.appending(path: "AppIcon.appiconset")
        _ = try Icon.generate(mark: mark, into: out)

        try "not a png at all".write(
            to: out.appending(path: "icon_16x16.png"), atomically: true, encoding: .utf8)

        let findings = try Icon.audit(out)
        #expect(findings.count == 1)
        #expect(findings.first?.kind == .unreadable("icon_16x16.png"))
    }

    @Test func auditPassesOnAGeneratedSet() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = try Self.writeMark(in: dir)
        let out = dir.appending(path: "AppIcon.appiconset")
        _ = try Icon.generate(mark: mark, into: out)
        #expect(try Icon.audit(out).isEmpty)
    }
}

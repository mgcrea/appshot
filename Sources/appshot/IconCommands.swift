import AppShotKit
import ArgumentParser
import Foundation

// MARK: - icon

struct Icon_: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "icon",
        abstract: "Build a macOS .appiconset from one mark, or audit an existing one.",
        discussion: """
            Takes artwork you already have (SVG, PDF or PNG) and does the mechanical \
            part: Apple's icon grid, all ten slots at exact pixel sizes, Contents.json.

            It deliberately does not own what is *in* the mark — that is per-project \
            design, and a tool that generated it would be guessing.

              appshot icon build --from Design/mark.svg --plate '#0b0b0c' \\
                  --tint '#f5f3ee' --out MyApp/Assets.xcassets/AppIcon.appiconset

              appshot icon check --out MyApp/Assets.xcassets/AppIcon.appiconset
            """,
        subcommands: [IconBuild.self, IconCheck.self],
        defaultSubcommand: IconBuild.self
    )
}

struct IconSetOption: ParsableArguments {
    @Option(name: .long, help: "Path to the .appiconset directory.")
    var out: String

    var outURL: URL { URL(fileURLWithPath: out) }
}

// MARK: - icon build

struct IconBuild: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Render every slot of a macOS icon set from one mark.")

    @Option(name: .long, help: "The mark: .svg, .pdf or a bitmap. Aspect-fitted and centred.")
    var from: String

    @OptionGroup var set: IconSetOption

    @Option(
        name: .long,
        help: "Plate colour behind the mark, #RRGGBB. Omit for artwork that carries its own.")
    var plate: String?

    @Option(
        name: .long,
        help: """
            Two or more #RRGGBB stops for a gradient plate, comma separated. \
            Overrides --plate.
            """)
    var plateGradient: String?

    @Option(name: .long, help: "Gradient angle in degrees, clockwise, y-down.")
    var plateAngle: Double = 45

    @Option(
        name: .long,
        help: """
            Fill the mark's shape with this #RRGGBB instead of its own colours. \
            For a mark authored with currentColor, which renders black on its own.
            """)
    var tint: String?

    @Option(
        name: .long,
        help: "Fraction of the canvas the mark spans, before aspect-fitting.")
    var markFraction: Double = AppShotKit.Icon.defaultMarkFraction

    func run() throws {
        let markURL = URL(fileURLWithPath: from)
        guard FileManager.default.fileExists(atPath: markURL.path) else {
            throw CLIError("no such mark: \(from)")
        }

        var plateSpec: AppShotKit.Icon.Plate = .none
        if let stops = plateGradient {
            plateSpec = try AppShotKit.Icon.gradientPlate(
                hexes: stops.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                },
                angle: plateAngle)
        } else if let plate {
            plateSpec = .solid(plate)
        }

        let written = try AppShotKit.Icon.generate(
            mark: markURL,
            into: set.outURL,
            options: AppShotKit.Icon.Options(
                plate: plateSpec, tint: tint, markFraction: markFraction))

        print("✓ wrote \(written.count) slot(s) + Contents.json into \(set.out)")
        let largest = written.max { $0.slot.pixels < $1.slot.pixels }
        if let largest {
            print("  largest \(largest.slot.filename) at \(largest.slot.pixels)px")
        }

        // Audit what was just written rather than trusting the loop above. The whole
        // point of this command is that a plausible-looking icon set is rejected at
        // upload; reporting success without re-reading the files would reproduce that.
        let findings = try AppShotKit.Icon.audit(set.outURL)
        guard findings.isEmpty else {
            throw AppShotError.iconSetIncomplete(set.outURL, findings)
        }
    }
}

// MARK: - icon check

struct IconCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Fail if an .appiconset is missing slots or has wrong-sized images.",
        discussion: """
            Catches, in milliseconds, what App Store Connect otherwise tells you after \
            a full archive, export and upload:

              Missing required icon. The application bundle does not have an icon in \
            ICNS format containing a 512pt x 512pt @2x image. (90236)

            A Contents.json that declares every slot while the directory holds no \
            images builds and runs fine, showing a blank icon nobody notices.
            """)

    @OptionGroup var set: IconSetOption

    func run() throws {
        let findings = try AppShotKit.Icon.audit(set.outURL)
        guard findings.isEmpty else {
            throw AppShotError.iconSetIncomplete(set.outURL, findings)
        }
        print("✓ \(set.out) has all \(AppShotKit.Icon.macSlots.count) macOS slots at the right sizes")
    }
}

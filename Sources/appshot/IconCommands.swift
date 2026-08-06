import AppShotKit
import ArgumentParser
import Foundation

// MARK: - icon

struct Icon_: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "icon",
        abstract: "Build a macOS app icon from one mark, or audit an existing one.",
        discussion: """
            Takes artwork you already have (SVG, PDF or PNG) and does the mechanical \
            part: Apple's icon grid, every slot at exact pixel sizes, and the manifest.

            It deliberately does not own what is *in* the mark — that is per-project \
            design, and a tool that generated it would be guessing.

            The --out extension picks the format, because the two want opposite \
            artwork and guessing wrong is silent:

              .appiconset   a rounded 824pt plate on a 1024pt canvas, ten slots
              .icon         Icon Composer: one square 1024pt layer, opaque to the edge

              appshot icon build --from Design/mark.svg --plate '#0b0b0c' \\
                  --tint '#f5f3ee' --out MyApp/Assets.xcassets/AppIcon.appiconset

              appshot icon build --from Design/mark.svg --plate '#0b0b0c' \\
                  --tint '#f5f3ee' --out MyApp/MyApp.icon

              appshot icon check --out MyApp/MyApp.icon
            """,
        subcommands: [IconBuild.self, IconCheck.self],
        defaultSubcommand: IconBuild.self
    )
}

/// Which grid `--out` is asking for.
///
/// Derived from the extension rather than a `--format` flag: the path already says
/// which one it is, and a flag that could disagree with it is a way to write a
/// full-bleed layer into an `.appiconset` and not find out until the Dock.
enum IconFormat {
    case appiconset
    case iconBundle

    init(out: URL) throws {
        switch out.pathExtension {
        case "appiconset": self = .appiconset
        case "icon": self = .iconBundle
        default: throw AppShotError.unknownIconFormat(out)
        }
    }
}

struct IconSetOption: ParsableArguments {
    @Option(
        name: .long,
        help: "Path to the .appiconset or .icon directory. The extension picks the format.")
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
        help: """
            Fraction of the canvas the mark spans, before aspect-fitting. The canvas is \
            not the plate for an .appiconset, so the same number reads a quarter larger \
            in a .icon — the command prints what it lands at on the composed plate.
            """)
    var markFraction: Double = AppShotKit.Icon.defaultMarkFraction

    func run() throws {
        let markURL = URL(fileURLWithPath: from)
        guard FileManager.default.fileExists(atPath: markURL.path) else {
            throw CLIError("no such mark: \(from)")
        }
        let format = try IconFormat(out: set.outURL)

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
        let options = AppShotKit.Icon.Options(
            plate: plateSpec, tint: tint, markFraction: markFraction)

        // Printed for both formats because it is the number that is comparable between
        // them, and the one that decides whether the icon reads timid next to its peers.
        // The raw --mark-fraction is not: it is measured against a canvas that is the
        // plate in one format and 1024/824 of it in the other.
        let onPlate: Double
        switch format {
        case .appiconset:
            let written = try AppShotKit.Icon.generate(
                mark: markURL, into: set.outURL, options: options)
            onPlate = AppShotKit.Icon.composedPlateFraction(markFraction)

            print("✓ wrote \(written.count) slot(s) + Contents.json into \(set.out)")
            if let largest = written.max(by: { $0.slot.pixels < $1.slot.pixels }) {
                print("  largest \(largest.slot.filename) at \(largest.slot.pixels)px")
            }

            // Audit what was just written rather than trusting the loop above. The whole
            // point of this command is that a plausible-looking icon set is rejected at
            // upload; reporting success without re-reading the files would reproduce that.
            let findings = try AppShotKit.Icon.audit(set.outURL)
            guard findings.isEmpty else {
                throw AppShotError.iconSetIncomplete(set.outURL, findings)
            }

        case .iconBundle:
            let written = try AppShotKit.IconComposer.generate(
                mark: markURL, into: set.outURL, options: options)
            onPlate = AppShotKit.IconComposer.composedPlateFraction(markFraction)

            print("✓ wrote icon.json + Assets/ into \(set.out)")
            print(
                "  layer \(written.layer.lastPathComponent) at "
                    + "\(AppShotKit.IconComposer.layerPixels)px, square and opaque")

            let findings = try AppShotKit.IconComposer.audit(set.outURL)
            guard findings.isEmpty else {
                throw AppShotError.iconBundleInvalid(set.outURL, findings)
            }
        }

        let percent = (onPlate * 1000).rounded() / 10
        print("  mark spans \(percent)% of the composed plate (peers sit at 70–80%)")
    }
}

// MARK: - icon check

struct IconCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Fail if an app icon is missing images or carries the wrong artwork.",
        discussion: """
            For an .appiconset, catches in milliseconds what App Store Connect \
            otherwise tells you after a full archive, export and upload:

              Missing required icon. The application bundle does not have an icon in \
            ICNS format containing a 512pt x 512pt @2x image. (90236)

            A Contents.json that declares every slot while the directory holds no \
            images builds and runs fine, showing a blank icon nobody notices.

            For a .icon, catches the migration mistake instead: a base layer that \
            still carries the rounded plate an .appiconset needs, which the system \
            then masks a second time.
            """)

    @OptionGroup var set: IconSetOption

    func run() throws {
        switch try IconFormat(out: set.outURL) {
        case .appiconset:
            let findings = try AppShotKit.Icon.audit(set.outURL)
            guard findings.isEmpty else {
                throw AppShotError.iconSetIncomplete(set.outURL, findings)
            }
            print(
                "✓ \(set.out) has all \(AppShotKit.Icon.macSlots.count) macOS slots "
                    + "at the right sizes")

        case .iconBundle:
            let findings = try AppShotKit.IconComposer.audit(set.outURL)
            guard findings.isEmpty else {
                throw AppShotError.iconBundleInvalid(set.outURL, findings)
            }
            print(
                "✓ \(set.out) has a square, fully opaque "
                    + "\(AppShotKit.IconComposer.layerPixels)px base layer")
        }
    }
}

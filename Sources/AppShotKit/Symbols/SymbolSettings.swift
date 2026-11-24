import Foundation

/// A family's `symbols.json`, beside its SVGs. Every key is optional; a folder with no
/// file gets the defaults.
public struct SymbolSettings: Codable, Sendable, Equatable {
    /// The Regular stroke, in box units (the box is 100 across).
    public var strokeWidth: Double
    /// Space either side of the outlined glyph, in box units.
    public var sideBearing: Double
    /// Prepended to each file name to make its asset name.
    public var prefix: String
    /// The asset folder to write into, relative to the sources folder.
    public var out: String?
    /// Stock SF Symbols the family sits with, for the sheet.
    public var companions: [String]
    /// The sheet's extra columns.
    public var variants: [SymbolVariant]
    /// Images the sheet places beside the glyphs; paths may lie outside the repo.
    public var references: [String]

    public static let fileName = "symbols.json"

    public init(
        strokeWidth: Double = 8, sideBearing: Double = 4, prefix: String = "", out: String? = nil,
        companions: [String] = [], variants: [SymbolVariant] = [], references: [String] = []
    ) {
        self.strokeWidth = strokeWidth
        self.sideBearing = sideBearing
        self.prefix = prefix
        self.out = out
        self.companions = companions
        self.variants = variants
        self.references = references
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SymbolSettings()
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? defaults.strokeWidth
        sideBearing = try c.decodeIfPresent(Double.self, forKey: .sideBearing) ?? defaults.sideBearing
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? defaults.prefix
        out = try c.decodeIfPresent(String.self, forKey: .out)
        companions = try c.decodeIfPresent([String].self, forKey: .companions) ?? []
        variants = try c.decodeIfPresent([SymbolVariant].self, forKey: .variants) ?? []
        references = try c.decodeIfPresent([String].self, forKey: .references) ?? []
    }

    /// The folder's `symbols.json`, or the defaults when it has none.
    public static func read(in folder: URL) throws -> SymbolSettings {
        let url = folder.appending(path: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return SymbolSettings() }
        let settings: SymbolSettings
        do {
            settings = try JSONDecoder().decode(SymbolSettings.self, from: Data(contentsOf: url))
        } catch let error as DecodingError {
            throw AppShotError.invalidConfig(url, Self.describe(error))
        } catch {
            throw AppShotError.invalidConfig(url, error.localizedDescription)
        }
        try settings.validate(url)
        return settings
    }

    private func validate(_ url: URL) throws {
        guard strokeWidth > 0 else {
            throw AppShotError.invalidConfig(url, "strokeWidth must be above 0, in box units (default 8)")
        }
        guard sideBearing >= 0 else {
            throw AppShotError.invalidConfig(url, "sideBearing cannot be negative (default 4)")
        }
        for variant in variants {
            guard variant.colors.count == 3 else {
                throw AppShotError.invalidConfig(
                    url,
                    "variant \"\(variant.name)\" gives \(variant.colors.count) colours; it needs three, "
                        + "for the outline, the touch and the wash")
            }
            for color in variant.colors where !SymbolVariant.isPaletteColor(color) {
                throw AppShotError.invalidConfig(
                    url,
                    "variant \"\(variant.name)\": \"\(color)\" is not a colour; use #RRGGBB, #RRGGBBAA, "
                        + "\"primary\" or \"accent\"")
            }
            if let tile = variant.tile, !SymbolVariant.isHexColor(tile) {
                throw AppShotError.invalidConfig(
                    url, "variant \"\(variant.name)\": tile \"\(tile)\" is not #RRGGBB or #RRGGBBAA")
            }
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(let type, let context), .valueNotFound(let type, let context):
            let key = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "\(key.isEmpty ? "the file" : key) should be \(type)"
        case .keyNotFound(let key, _):
            return "missing \"\(key.stringValue)\""
        case .dataCorrupted(let context):
            return "not valid JSON: \(context.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }
}

/// One of the sheet's variant columns: the three palette colours, in palette order
/// (outline, touch, wash), and a tile background.
public struct SymbolVariant: Codable, Sendable, Equatable {
    public let name: String
    /// Each `"#RRGGBB"`, `"#RRGGBBAA"`, `"primary"` or `"accent"`.
    public let colors: [String]
    public let tile: String?

    public init(name: String, colors: [String], tile: String? = nil) {
        self.name = name
        self.colors = colors
        self.tile = tile
    }

    static func isPaletteColor(_ value: String) -> Bool {
        value == "primary" || value == "accent" || isHexColor(value)
    }

    static func isHexColor(_ value: String) -> Bool {
        guard value.first == "#" else { return false }
        let hex = value.dropFirst()
        return (hex.count == 6 || hex.count == 8) && hex.allSatisfy(\.isHexDigit)
    }
}

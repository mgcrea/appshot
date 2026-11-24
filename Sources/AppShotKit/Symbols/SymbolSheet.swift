import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A contact sheet of a compiled symbol folder: every symbol, then the stock symbols the
/// family sits with, in each mode, size and appearance it is judged in.
///
/// The PNG holds the glyphs only and a repo may commit it. The HTML page adds the reference
/// images, which are often other vendors' icons and are never committed.
public enum SymbolSheet {
    /// The point sizes the monochrome and palette columns draw at: body text first.
    public static let sizes: [CGFloat] = [13, 16, 20, 28]

    // The grid, in points. Every measure is constant, so a symbol adds one row and a
    // variant one column in each appearance, whatever they draw.
    static let scale: CGFloat = 2
    static let margin: CGFloat = 16
    static let nameWidth: CGFloat = 150
    static let cellWidth: CGFloat = 40
    static let rowHeight: CGFloat = 44
    static let labelWidth: CGFloat = 100
    static let headerHeight: CGFloat = 46
    /// The gap and rule between the family's rows and the companions'.
    static let ruleHeight: CGFloat = 17
    static let tileSide: CGFloat = 30

    /// One column of an appearance's half, left to right.
    enum Column: Equatable {
        case monochrome(CGFloat)
        case hierarchical
        case palette(CGFloat)
        case pink
        case variant(Int)
        case label

        var width: CGFloat { self == .label ? SymbolSheet.labelWidth : SymbolSheet.cellWidth }
    }

    static func columns(variants: Int) -> [Column] {
        sizes.map(Column.monochrome) + [.hierarchical] + sizes.map(Column.palette) + [.pink]
            + (0..<variants).map(Column.variant) + [.label]
    }

    static func halfWidth(variants: Int) -> CGFloat {
        columns(variants: variants).reduce(0) { $0 + $1.width }
    }

    /// Where a cell of the light half sits, in points from the sheet's top left: `column`
    /// counts the half's columns from the first monochrome one.
    static func cellRect(row: Int, column: Int) -> CGRect {
        CGRect(
            x: margin + nameWidth + CGFloat(column) * cellWidth,
            y: margin + headerHeight + CGFloat(row) * rowHeight, width: cellWidth, height: rowHeight)
    }

    /// The sheet as a PNG, at twice its point size.
    ///
    /// - Throws: `AppShotError.symbolNoActool` or `.symbolCatalogRejected` from compiling, and
    ///   `.symbolCatalogRejected` for a symbol that compiled but does not load.
    public static func png(assets: URL, settings: SymbolSettings) throws -> Data {
        let compiled = try SymbolCatalog.compile(assets).bundle
        defer { try? FileManager.default.removeItem(at: compiled.bundleURL.deletingLastPathComponent()) }

        var rows: [Row] = []
        for url in SymbolCheck.symbolsets(in: assets).sorted(by: {
            $0.lastPathComponent < $1.lastPathComponent
        }) {
            let name = url.deletingPathExtension().lastPathComponent
            guard let image = NSImage(symbolName: name, bundle: compiled, variableValue: 1) else {
                throw AppShotError.symbolCatalogRejected(
                    "\(name).symbolset compiled, but no symbol \(name) loads from it")
            }
            rows.append(Row(name: name, image: image, companion: false))
        }
        let companions = settings.companions.map { name in
            Row(
                name: name, image: NSImage(systemSymbolName: name, accessibilityDescription: nil),
                companion: true)
        }
        guard let image = draw(rows: rows, companions: companions, variants: settings.variants) else {
            throw AppShotError.symbolCatalogRejected("the sheet could not be drawn")
        }
        return try encode(image)
    }

    /// The review page: a header, the sheet, then the reference images with their names.
    ///
    /// - Parameter referencesRoot: what a relative path in `settings.references` is read from.
    /// - Throws: `AppShotError.symbolMissingReference` naming the first image that is not
    ///   there, before anything is compiled; then what `png` throws.
    public static func html(assets: URL, settings: SymbolSettings, referencesRoot: URL) throws -> String {
        var references: [(name: String, mime: String, data: Data)] = []
        for path in settings.references {
            let expanded = (path as NSString).expandingTildeInPath
            // A root read as a file would lose its last component, so a relative path is
            // appended rather than resolved.
            let url =
                (expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded) : referencesRoot.appending(path: expanded))
                .standardizedFileURL
            guard let data = try? Data(contentsOf: url) else {
                throw AppShotError.symbolMissingReference(url)
            }
            references.append((url.lastPathComponent, mime(url), data))
        }
        let sheet = try png(assets: assets, settings: settings)
        let width = Int(CGFloat(pixelWidth(sheet)) / scale)

        var figures = ""
        for reference in references {
            figures += """
                <figure><img src="data:\(reference.mime);base64,\(reference.data.base64EncodedString())" \
                alt="\(escape(reference.name))"><figcaption>\(escape(reference.name))</figcaption></figure>

                """
        }
        let title = escape(assets.lastPathComponent)
        return """
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(title) symbols</title>
            <style>
            :root { color-scheme: light dark; --bg: #f5f5f7; --fg: #1d1d1f; --muted: #6e6e73; }
            @media (prefers-color-scheme: dark) { :root { --bg: #1d1d1f; --fg: #f5f5f7; --muted: #a1a1a6; } }
            body { margin: 0; padding: 24px 16px; background: var(--bg); color: var(--fg);
              font: 14px -apple-system, BlinkMacSystemFont, sans-serif; }
            h1 { font-size: 20px; margin: 0 0 4px; }
            p { color: var(--muted); margin: 0 0 16px; }
            .sheet { overflow-x: auto; }
            .sheet img { display: block; max-width: none; }
            .references { display: flex; flex-wrap: wrap; gap: 16px; margin-top: 24px; }
            figure { margin: 0; }
            figure img { display: block; max-height: 160px; max-width: 100%; }
            figcaption { color: var(--muted); font-size: 12px; margin-top: 4px; }
            </style>
            </head>
            <body>
            <h1>\(title)</h1>
            <p>\(rowsSummary(assets: assets, settings: settings)). Light, then dark; monochrome and \
            palette at \(sizes.map { "\(Int($0))" }.joined(separator: ", ")) points.</p>
            <div class="sheet"><img src="data:image/png;base64,\(sheet.base64EncodedString())" \
            width="\(width)" alt="The symbol sheet"></div>
            <div class="references">
            \(figures)</div>
            </body>
            </html>

            """
    }

    // MARK: - Drawing

    struct Row {
        let name: String
        let image: NSImage?
        let companion: Bool
    }

    /// The colours of one appearance, resolved while it is the drawing appearance.
    struct Palette {
        let background: NSColor
        let label: NSColor
        let secondary: NSColor
        let accent: NSColor
        let pink: NSColor
        let separator: NSColor

        init() {
            func resolved(_ color: NSColor) -> NSColor { color.usingColorSpace(.sRGB) ?? color }
            background = resolved(.windowBackgroundColor)
            label = resolved(.labelColor)
            secondary = resolved(.secondaryLabelColor)
            accent = resolved(.controlAccentColor)
            pink = resolved(.systemPink)
            separator = resolved(.separatorColor)
        }
    }

    static func draw(rows: [Row], companions: [Row], variants: [SymbolVariant]) -> CGImage? {
        let half = halfWidth(variants: variants.count)
        let width = margin * 2 + nameWidth + half * 2
        let rule = companions.isEmpty ? 0 : ruleHeight
        let height = margin * 2 + headerHeight + CGFloat(rows.count + companions.count) * rowHeight + rule
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let cg = CGContext(
                data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8,
                bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Points, from the top left, as the layout reads.
        cg.translateBy(x: 0, y: height * scale)
        cg.scaleBy(x: scale, y: -scale)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let light = NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
        var page: Palette?
        light.performAsCurrentDrawingAppearance { page = Palette() }
        guard let page else { return nil }
        page.background.setFill()
        CGRect(x: 0, y: 0, width: width, height: height).fill()

        // The names, down the left.
        let all = rows + companions
        for (index, row) in all.enumerated() {
            let y = rowY(index, rows: rows.count, rule: rule)
            let font = NSFont.systemFont(ofSize: 11, weight: row.companion ? .regular : .medium)
            let name = row.image == nil ? "\(row.name) (not found)" : row.name
            text(
                name, in: CGRect(x: margin, y: y, width: nameWidth - 8, height: rowHeight), font: font,
                color: row.companion ? page.secondary : page.label)
        }

        for (offset, appearanceName) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            guard let appearance = NSAppearance(named: appearanceName) else { continue }
            let left = margin + nameWidth + CGFloat(offset) * half
            appearance.performAsCurrentDrawingAppearance {
                let colors = Palette()
                colors.background.setFill()
                CGRect(x: left, y: margin, width: half, height: height - margin * 2).fill()
                header(
                    offset == 0 ? "Light" : "Dark", left: left, variants: variants, colors: colors)
                if rule > 0 {
                    colors.separator.setFill()
                    let y = margin + headerHeight + CGFloat(rows.count) * rowHeight + rule / 2
                    CGRect(x: left + 8, y: y, width: half - 16, height: 1).fill()
                }
                for (index, row) in all.enumerated() {
                    guard let image = row.image else { continue }
                    var x = left
                    let y = rowY(index, rows: rows.count, rule: rule)
                    for column in columns(variants: variants.count) {
                        let cell = CGRect(x: x, y: y, width: column.width, height: rowHeight)
                        draw(image, column: column, in: cell, variants: variants, colors: colors)
                        x += column.width
                    }
                }
            }
        }
        return cg.makeImage()
    }

    static func rowY(_ index: Int, rows: Int, rule: CGFloat) -> CGFloat {
        margin + headerHeight + CGFloat(index) * rowHeight + (index >= rows ? rule : 0)
    }

    /// The half's title, then each column's group over its size.
    static func header(_ title: String, left: CGFloat, variants: [SymbolVariant], colors: Palette) {
        text(
            title, in: CGRect(x: left + 6, y: margin + 4, width: 200, height: 16),
            font: .systemFont(ofSize: 12, weight: .semibold), color: colors.label)
        let small = NSFont.systemFont(ofSize: 9)
        var x = left
        for column in columns(variants: variants.count) {
            let group: String?
            let detail: String
            switch column {
            case .monochrome(let size):
                group = size == sizes[0] ? "monochrome" : nil
                detail = "\(Int(size))"
            case .hierarchical:
                group = "hier."
                detail = "20"
            case .palette(let size):
                group = size == sizes[0] ? "palette" : nil
                detail = "\(Int(size))"
            case .pink:
                group = "pink"
                detail = "20"
            case .variant(let index):
                group = variants[index].name
                detail = "20"
            case .label:
                group = "label"
                detail = "13"
            }
            if let group {
                // A group's name spans the cells it heads, and a long one is cut short there.
                let span =
                    column == .monochrome(sizes[0]) || column == .palette(sizes[0]) ? CGFloat(sizes.count) : 1
                text(
                    group, in: CGRect(x: x + 4, y: margin + 22, width: span * column.width - 4, height: 12),
                    font: small, color: colors.secondary)
            }
            text(
                detail, in: CGRect(x: x + 4, y: margin + 33, width: column.width - 4, height: 12),
                font: small,
                color: colors.secondary)
            x += column.width
        }
    }

    static func draw(
        _ image: NSImage, column: Column, in cell: CGRect, variants: [SymbolVariant], colors: Palette
    ) {
        func sized(_ size: CGFloat, _ mode: NSImage.SymbolConfiguration) -> NSImage? {
            image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: size, weight: .regular).applying(mode))
        }
        func palette(_ accent: NSColor) -> NSImage.SymbolConfiguration {
            NSImage.SymbolConfiguration(paletteColors: [
                colors.label, accent, colors.label.withAlphaComponent(0.18),
            ])
        }
        switch column {
        case .monochrome(let size):
            centre(sized(size, .preferringMonochrome()).map { tinted($0, colors.label) }, in: cell)
        case .hierarchical:
            centre(sized(20, NSImage.SymbolConfiguration(hierarchicalColor: colors.label)), in: cell)
        case .palette(let size):
            centre(sized(size, palette(colors.accent)), in: cell)
        case .pink:
            centre(sized(20, palette(colors.pink)), in: cell)
        case .variant(let index):
            let variant = variants[index]
            if let tile = variant.tile.flatMap(color) {
                tile.setFill()
                let square = CGRect(
                    x: cell.midX - tileSide / 2, y: cell.midY - tileSide / 2, width: tileSide,
                    height: tileSide)
                NSBezierPath(roundedRect: square, xRadius: 7, yRadius: 7).fill()
            }
            let tones = variant.colors.map { value -> NSColor in
                switch value {
                case "primary": return colors.label
                case "accent": return colors.accent
                default: return color(value) ?? colors.label
                }
            }
            centre(sized(20, NSImage.SymbolConfiguration(paletteColors: tones)), in: cell)
        case .label:
            // As a Label lays them out: the symbol on the text's baseline, then the word.
            let font = NSFont.systemFont(ofSize: 13)
            let baseline = (cell.midY + (font.ascender + font.descender) / 2).rounded()
            var x = cell.minX + 8
            if let symbol = sized(13, .preferringMonochrome()).map({ tinted($0, colors.label) }) {
                let bottom = baseline + symbol.alignmentRect.minY
                symbol.draw(
                    in: CGRect(
                        x: x, y: bottom - symbol.size.height, width: symbol.size.width,
                        height: symbol.size.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += symbol.alignmentRect.width + 6
            }
            NSAttributedString(string: "Extrude", attributes: [.font: font, .foregroundColor: colors.label])
                .draw(at: CGPoint(x: x, y: baseline - font.ascender))
        }
    }

    static func centre(_ image: NSImage?, in cell: CGRect) {
        guard let image else { return }
        let size = image.size
        let rect = CGRect(
            x: (cell.midX - size.width / 2).rounded(), y: (cell.midY - size.height / 2).rounded(),
            width: size.width, height: size.height)
        image.draw(
            in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// `image`'s drawn pixels, each in `color` at its own coverage: a monochrome symbol in a
    /// colour, as a template image is tinted on screen.
    static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.alignmentRect = image.alignmentRect
        return tinted
    }

    static func text(_ string: String, in rect: CGRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ]
        let line = NSAttributedString(string: string, attributes: attributes)
        let lineHeight = font.ascender - font.descender
        let box = CGRect(
            x: rect.minX, y: rect.midY - lineHeight / 2, width: rect.width, height: lineHeight + 2)
        line.draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// `#RRGGBB` or `#RRGGBBAA`, in sRGB.
    static func color(_ hex: String) -> NSColor? {
        guard SymbolVariant.isHexColor(hex), let value = UInt64(hex.dropFirst(), radix: 16) else {
            return nil
        }
        let rgba = hex.count == 7 ? value << 8 | 0xFF : value
        func channel(_ shift: UInt64) -> CGFloat { CGFloat((rgba >> shift) & 0xFF) / 255 }
        return NSColor(srgbRed: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
    }

    // MARK: - Files

    static func encode(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { throw AppShotError.symbolCatalogRejected("the sheet could not be encoded as PNG") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AppShotError.symbolCatalogRejected("the sheet could not be encoded as PNG")
        }
        return data as Data
    }

    static func pixelWidth(_ png: Data) -> Int {
        guard
            let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return 0 }
        return image.width
    }

    static func rowsSummary(assets: URL, settings: SymbolSettings) -> String {
        let count = SymbolCheck.symbolsets(in: assets).count
        let symbols = "\(count) symbol\(count == 1 ? "" : "s")"
        guard !settings.companions.isEmpty else { return symbols }
        return "\(symbols), then \(settings.companions.count) stock for company"
    }

    static func mime(_ url: URL) -> String {
        UTType(filenameExtension: url.pathExtension.lowercased())?.preferredMIMEType
            ?? "application/octet-stream"
    }

    static func escape(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

import CoreGraphics
import Foundation
import Testing

@testable import AppShotKit

/// Background layers draw between the gradient and the window. A layer that went
/// missing would leave a store set that still looks finished, so these pin that a
/// layer is drawn, is refused when it cannot be, and changes nothing when absent.
struct BackgroundLayerTests {
    static let plate = Config.Background(
        angle: 90, stops: [.init(offset: 0, color: "#0D271E"), .init(offset: 1, color: "#235F49")])

    static let fan = Config.Layer(
        kind: "fan", color: "#FBF8EF", opacity: 0.6, sun: "#F6C66A",
        fade: .init(from: 0.1, to: 0.5, floor: 0.2))

    /// RGBA bytes of a background drawn alone.
    static func render(_ background: Config.Background, width: Int = 360, height: Int = 240) -> [UInt8] {
        let ctx = Image.context(width: width, height: height)!
        Compose.drawBackground(ctx, background, width: Double(width), height: Double(height))
        let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: ctx.bytesPerRow * height))
    }

    /// Summed channel difference over one band of rows, y-down.
    static func difference(_ a: [UInt8], _ b: [UInt8], rows: Range<Int>, width: Int = 360) -> Int {
        rows.reduce(0) { sum, y in
            let row = y * width * 4
            return sum + (0..<(width * 4)).reduce(0) { $0 + abs(Int(a[row + $1]) - Int(b[row + $1])) }
        }
    }

    @Test func decodesALayerAndLeavesOldConfigsWithout() throws {
        let json = """
            { "angle": 90, "stops": [{ "offset": 0, "color": "#000000" }],
              "layers": [{ "kind": "fan", "color": "#FFFFFF", "opacity": 0.1, "falloff": 0.7,
                           "fade": { "from": 0.1, "to": 0.4, "floor": 0.3 } }] }
            """
        let background = try JSONDecoder().decode(Config.Background.self, from: Data(json.utf8))
        #expect(background.layers?.first?.falloff == 0.7)
        #expect(background.layers?.first?.fade == .init(from: 0.1, to: 0.4, floor: 0.3))
        #expect(try ConfigTests.decode().themes["dark"]?.background.layers == nil)
    }

    /// The same bytes as before layers existed, so no consuming project's goldens move.
    @Test func noLayersDrawsTheGradientAlone() {
        let ctx = Image.context(width: 360, height: 240)!
        Compose.drawGradient(ctx, Self.plate, width: 360, height: 240)
        let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let gradient = Array(UnsafeBufferPointer(start: bytes, count: ctx.bytesPerRow * 240))
        #expect(Self.render(Self.plate) == gradient)
    }

    @Test func aFanIsDrawnAndQuietUnderTheCaption() {
        var withFan = Self.plate
        withFan.layers = [Self.fan]
        let plain = Self.render(Self.plate)
        let drawn = Self.render(withFan)
        let top = Self.difference(plain, drawn, rows: 0..<24)
        let bottom = Self.difference(plain, drawn, rows: 180..<204)
        #expect(bottom > 0)
        // The fade holds the top at a fifth of its strength, and the outer rings are
        // fainter anyway.
        #expect(top * 3 < bottom)
    }

    /// The sun is a solid disc, as on the icon, out to its edge: a sun fading over its
    /// outer fifth read as out of focus on a store header.
    @Test func theSunIsSolidToItsEdge() {
        var withFan = Self.plate
        withFan.layers = [Self.fan]
        let drawn = Self.render(withFan)
        let g = Compose.FanGeometry(Self.fan, width: 360, height: 240)
        let radius = g.sunRadius - g.gap
        func pixel(above distance: Double) -> [Int] {
            let y = Int((g.center.y - distance).rounded(.down))
            let i = (y * 360 + Int(g.center.x)) * 4
            return drawn[i..<(i + 3)].map(Int.init)
        }
        // #F6C66A two pixels inside the edge, and the ground two pixels outside it.
        let inside = pixel(above: radius - 2)
        #expect(abs(inside[0] - 0xF6) <= 2 && abs(inside[1] - 0xC6) <= 2 && abs(inside[2] - 0x6A) <= 2)
        let outside = pixel(above: radius + 2)
        #expect(outside[0] < 0xC0)
    }

    @Test func ringsReachTheTopEdgeOnEveryCanvas() {
        for (w, h) in [(2880.0, 1800.0), (1320.0, 2868.0), (2752.0, 2064.0)] {
            let g = Compose.FanGeometry(Self.fan, width: w, height: h)
            #expect(g.sunRadius + Double(g.rings) * g.ringWidth >= g.center.y)
            #expect(g.sunRadius + Double(g.rings - 1) * g.ringWidth < g.center.y)
        }
        // Lengths follow the shorter side, so a Mac canvas's rings match an iPad's in kind.
        #expect(Compose.FanGeometry(Self.fan, width: 2880, height: 1800).ringWidth == 360)
        #expect(Compose.FanGeometry(Self.fan, width: 2880, height: 1800).rings == 5)
    }

    @Test func eachRingDoublesItsSegmentsUpToTheCap() {
        var layer = Self.fan
        layer.maxSegments = 16
        let g = Compose.FanGeometry(layer, width: 2880, height: 1800)
        #expect((1...6).map { g.segments(inRing: $0) } == [2, 4, 8, 16, 16, 16])
    }

    @Test func rejectsALayerItCannotDraw() throws {
        for edit: (inout Config.Layer) -> Void in [
            { $0.kind = "stripes" },
            { $0.color = "#FFF" },
            { $0.sun = "gold" },
            { $0.opacity = 1.5 },
            { $0.falloff = -0.1 },
            { $0.ringWidth = 0 },
            { $0.rings = 0 },
            { $0.fade = .init(from: 0.5, to: 0.2, floor: 0.3) },
        ] {
            var layer = Self.fan
            edit(&layer)
            var config = try ConfigTests.decode()
            config.themes["dark"]!.background.layers = [layer]
            #expect {
                try config.validate()
            } throws: { error in
                guard case AppShotError.invalidTheme(let appearance, _) = error else { return false }
                return appearance == "dark"
            }
        }
        var config = try ConfigTests.decode()
        config.themes["dark"]!.background.layers = [Self.fan]
        #expect(throws: Never.self) { try config.validate() }
    }

    static let waveform = Config.Layer(
        kind: "waveform", color: "#FFF8EE", opacity: 0.5,
        fade: .init(from: 0.15, to: 0.55, floor: 0.15),
        colors: ["#2F7BEA", "#EE8A12"], playhead: "#FFF8EE")

    @Test func decodesAWaveform() throws {
        let json = """
            { "angle": 155, "stops": [{ "offset": 0, "color": "#000000" }],
              "layers": [{ "kind": "waveform", "color": "#FFFFFF", "opacity": 0.4,
                           "colors": ["#2F7BEA", "#EE8A12"], "center": 0.5, "playhead": "#FFF8EE",
                           "clear": { "from": 0.3, "to": 0.7, "floor": 0.12 } }] }
            """
        let layer = try #require(
            try JSONDecoder().decode(Config.Background.self, from: Data(json.utf8)).layers?.first)
        #expect(layer.colors == ["#2F7BEA", "#EE8A12"])
        #expect(layer.clear == .init(from: 0.3, to: 0.7, floor: 0.12))
    }

    @Test func aWaveformIsDrawnInTheBandAndQuietUnderTheCaption() {
        var drawn = Self.plate
        drawn.layers = [Self.waveform]
        let plain = Self.render(Self.plate)
        let with = Self.render(drawn)
        // The band is centred at 80% of 240: rows 168-216 carry it, the caption rows
        // at the top carry nothing at all, being outside the band.
        #expect(Self.difference(plain, with, rows: 180..<200) > 0)
        #expect(Self.difference(plain, with, rows: 0..<40) == 0)
    }

    @Test func barsSpanTheWidthTakeTurnsAndStopPlayingAtThePlayhead() {
        for (w, h) in [(2560.0, 1600.0), (1320.0, 2868.0), (3840.0, 1646.0)] {
            let g = Compose.WaveformGeometry(Self.waveform, width: w, height: h)
            #expect(g.bars.first!.rect.minX <= 0 && g.bars.last!.rect.maxX >= w)
            #expect(Set(g.bars.map(\.voice)) == [0, 1])
            #expect(g.bars.allSatisfy { $0.played == ($0.rect.midX < 0.38 * w) })
            #expect(g.bars.allSatisfy { abs($0.rect.midY - 0.8 * h) < 0.001 })
            // Lengths follow the shorter side, like the fan's.
            #expect(abs(g.bars[0].rect.width - 0.022 * min(w, h)) < 0.001)
        }
    }

    @Test func turnsLastFiveToNineBars() {
        let turns = Compose.WaveformGeometry.heights(400).map(\.turn)
        var lengths: [Int] = []
        var run = 1
        for i in 1..<turns.count {
            if turns[i] == turns[i - 1] { run += 1 } else { lengths.append(run); run = 1 }
        }
        #expect(lengths.allSatisfy { (5...9).contains($0) })
        #expect(Compose.WaveformGeometry.heights(400).allSatisfy { (0.16...1).contains($0.height) })
    }

    @Test func clearQuietsTheSpanAndEasesBack() {
        let clear = Config.Clear(from: 0.3, to: 0.7, floor: 0.1)
        #expect(Compose.outside(clear, x: 0.5) == 0)
        #expect(Compose.outside(clear, x: 0.1) == 1)
        #expect(Compose.outside(clear, x: 0.9) == 1)
        #expect(abs(Compose.outside(clear, x: 0.27) - 0.5) < 1e-9)
    }

    @Test func rejectsAWaveformItCannotDraw() throws {
        for edit: (inout Config.Layer) -> Void in [
            { $0.colors = [] },
            { $0.colors = ["blue"] },
            { $0.playhead = "#FFF" },
            { $0.center = 1.2 },
            { $0.barWidth = 0 },
            { $0.unplayed = -0.1 },
            { $0.clear = .init(from: 0.7, to: 0.3, floor: 0.1) },
        ] {
            var layer = Self.waveform
            edit(&layer)
            var config = try ConfigTests.decode()
            config.themes["dark"]!.background.layers = [layer]
            #expect(throws: AppShotError.self) { try config.validate() }
        }
        var config = try ConfigTests.decode()
        config.themes["dark"]!.background.layers = [Self.waveform]
        #expect(throws: Never.self) { try config.validate() }
    }

    static let cadastre = Config.Layer(
        kind: "cadastre", color: "#FFFAF3", opacity: 0.5,
        fade: .init(from: 0.1, to: 0.5, floor: 0.2),
        fill: "#022A31", fillOpacity: 0.3)

    @Test func decodesACadastre() throws {
        let json = """
            { "angle": 90, "stops": [{ "offset": 0, "color": "#0A4450" }],
              "layers": [{ "kind": "cadastre", "color": "#FFFAF3", "opacity": 0.14,
                           "fill": "#022A31", "fillOpacity": 0.16, "fillShare": 0.25,
                           "rotation": -12, "lotWidth": 0.05, "depth": 0.07, "street": 0.02,
                           "lineWidth": 0.003 }] }
            """
        let layer = try #require(
            try JSONDecoder().decode(Config.Background.self, from: Data(json.utf8)).layers?.first)
        #expect(layer.fill == "#022A31" && layer.fillShare == 0.25 && layer.rotation == -12)
        #expect(layer.lotWidth == 0.05 && layer.depth == 0.07 && layer.street == 0.02)
    }

    @Test func aCadastreIsDrawnAndQuietUnderTheCaption() {
        var drawn = Self.plate
        drawn.layers = [Self.cadastre]
        let plain = Self.render(Self.plate)
        let with = Self.render(drawn)
        let top = Self.difference(plain, with, rows: 0..<24)
        let bottom = Self.difference(plain, with, rows: 180..<204)
        #expect(bottom > 0)
        #expect(top * 3 < bottom)
    }

    /// Every store canvas is covered to its corners, the plan is the same on every
    /// run, and lengths follow the shorter side.
    @Test func lotsCoverEveryCanvasTheSameWayEachRun() {
        for (w, h) in [(2880.0, 1800.0), (1320.0, 2868.0), (2752.0, 2064.0), (3840.0, 1646.0)] {
            let g = Compose.CadastreGeometry(Self.cadastre, width: w, height: h)
            #expect(g == Compose.CadastreGeometry(Self.cadastre, width: w, height: h))
            let near = 0.12 * min(w, h)
            for corner in [
                CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: 0, y: h), CGPoint(x: w, y: h),
            ] {
                #expect(
                    g.lots.contains { $0.corners.contains { hypot($0.x - corner.x, $0.y - corner.y) < near } }
                )
            }
            #expect(abs(g.lineWidth - 0.0026 * min(w, h)) < 0.001)
        }
    }

    @Test func shadesAShareOfLotsOnlyWithAFill() {
        let g = Compose.CadastreGeometry(Self.cadastre, width: 2880, height: 1800)
        let share = Double(g.lots.filter(\.shaded).count) / Double(g.lots.count)
        #expect((0.15...0.25).contains(share))
        var outlines = Self.cadastre
        outlines.fill = nil
        let unshaded = Compose.CadastreGeometry(outlines, width: 2880, height: 1800).lots.allSatisfy {
            !$0.shaded
        }
        #expect(unshaded)
    }

    /// A header's wordmark sits in the middle: `clear` quiets the lots there and
    /// leaves the sides alone.
    @Test func clearQuietsACadastreOverTheSpan() {
        var drawn = Self.plate
        var layer = Self.cadastre
        layer.fade = nil
        layer.clear = .init(from: 0.35, to: 0.65, floor: 0)
        drawn.layers = [layer]
        let plain = Self.render(Self.plate)
        let with = Self.render(drawn)
        func columns(_ range: Range<Int>) -> Int {
            (0..<240).reduce(0) { sum, y in
                sum
                    + range.reduce(0) { s, x in
                        let i = (y * 360 + x) * 4
                        return s + (0..<3).reduce(0) { $0 + abs(Int(plain[i + $1]) - Int(with[i + $1])) }
                    }
            }
        }
        #expect(columns(140..<220) == 0)
        #expect(columns(0..<80) > 0)
    }

    @Test func rejectsACadastreItCannotDraw() throws {
        for edit: (inout Config.Layer) -> Void in [
            { $0.fill = "teal" },
            { $0.fillOpacity = 1.2 },
            { $0.fillShare = -0.1 },
            { $0.lotWidth = 0 },
            { $0.depth = 0 },
            { $0.lineWidth = 0 },
            { $0.street = -0.01 },
            { $0.rotation = .infinity },
        ] {
            var layer = Self.cadastre
            edit(&layer)
            var config = try ConfigTests.decode()
            config.themes["dark"]!.background.layers = [layer]
            #expect(throws: AppShotError.self) { try config.validate() }
        }
        var config = try ConfigTests.decode()
        config.themes["dark"]!.background.layers = [Self.cadastre]
        #expect(throws: Never.self) { try config.validate() }
    }

    // MARK: staff

    static let staff = Config.Layer(
        kind: "staff", color: "#C41D3E", opacity: 0.5,
        fade: .init(from: 0.1, to: 0.5, floor: 0.2),
        playhead: "#F5B85C", noteColor: "#1E1B24", lit: "#E8780F")

    @Test func decodesAStaff() throws {
        let json = """
            { "angle": 90, "stops": [{ "offset": 0, "color": "#FEFAF2" }],
              "layers": [{ "kind": "staff", "color": "#C41D3E", "opacity": 0.2,
                           "noteColor": "#1E1B24", "noteOpacity": 0.3, "lit": "#E8780F", "litOpacity": 0.8,
                           "playhead": "#F5B85C", "playheadAt": 0.3, "playheadOpacity": 0.2,
                           "lineGap": 0.018, "staffGap": 0.08, "measure": 0.4,
                           "lineWidth": 0.002 }] }
            """
        let layer = try #require(
            try JSONDecoder().decode(Config.Background.self, from: Data(json.utf8)).layers?.first)
        #expect(layer.noteColor == "#1E1B24" && layer.noteOpacity == 0.3 && layer.lit == "#E8780F")
        #expect(layer.litOpacity == 0.8)
        #expect(layer.lineGap == 0.018 && layer.staffGap == 0.08 && layer.measure == 0.4)
    }

    @Test func aStaffIsDrawnAndQuietUnderTheCaption() {
        var drawn = Self.plate
        drawn.layers = [Self.staff]
        let plain = Self.render(Self.plate)
        let with = Self.render(drawn)
        let top = Self.difference(plain, with, rows: 0..<24)
        let bottom = Self.difference(plain, with, rows: 180..<204)
        #expect(bottom > 0)
        #expect(top * 3 < bottom)
    }

    /// Staves of five evenly spaced lines reach past both edges of every store canvas,
    /// the score is the same on every run, and lengths follow the shorter side.
    @Test func stavesCoverEveryCanvasTheSameWayEachRun() {
        for (w, h) in [(2880.0, 1800.0), (1320.0, 2868.0), (2752.0, 2064.0), (3840.0, 1646.0)] {
            let g = Compose.StaffGeometry(Self.staff, width: w, height: h)
            #expect(g == Compose.StaffGeometry(Self.staff, width: w, height: h))
            let gap = 0.02 * min(w, h)
            #expect(g.lines.count % 5 == 0)
            for staff in stride(from: 0, to: g.lines.count, by: 5) {
                for i in 1..<5 {
                    #expect(abs(g.lines[staff + i].midY - g.lines[staff + i - 1].midY - gap) < 0.001)
                }
            }
            #expect(g.lines.first!.midY <= 0.1 * min(w, h))
            #expect(g.lines.last!.midY >= h - 0.1 * min(w, h))
            #expect(g.lines.allSatisfy { $0.minX == 0 && $0.width == w })
            #expect(abs(g.lineWidth - 0.0024 * min(w, h)) < 0.001)
        }
    }

    /// The icon's lit note: every staff has exactly one note in the playhead's column,
    /// lit, and never a rest there.
    @Test func theLitColumnHoldsOneNoteOnEveryStaff() {
        for at in [0.2, 0.38, 0.5, 0.81] {
            var layer = Self.staff
            layer.playheadAt = at
            let g = Compose.StaffGeometry(layer, width: 2880, height: 1800)
            let lit = g.notes.filter(\.lit)
            #expect(lit.count == g.lines.count / 5)
            #expect(lit.allSatisfy { abs($0.head.x - at * 2880) < 0.001 })
            #expect(abs(g.column.midX - at * 2880) < 0.001)
            #expect(g.notes.filter { g.column.contains(CGPoint(x: $0.head.x, y: 1)) }.allSatisfy { $0.lit })
        }
    }

    /// Heads stay on the staff or just outside it, stems go up below the middle line
    /// and down from it upwards, and barlines fall every four beats.
    @Test func notesAreSetAsAnEngraverWould() {
        let g = Compose.StaffGeometry(Self.staff, width: 2880, height: 1800)
        #expect(g.notes.count > 40)
        #expect(g.notes.allSatisfy { (-1...9).contains($0.step) })
        let single = g.notes.filter { !$0.beamed }
        #expect(single.allSatisfy { ($0.step < 4) == ($0.stem.minY < $0.head.y) })
        // A beam joins the two stems of its pair, at their far ends.
        #expect(!g.beams.isEmpty)
        let paired = g.notes.filter(\.beamed)
        #expect(paired.count == 2 * g.beams.count)
        for (beam, pair) in zip(g.beams, stride(from: 0, to: paired.count, by: 2).map { paired[$0...$0 + 1] })
        {
            let (a, b) = (pair.first!, pair.last!)
            let up = a.stem.minY < a.head.y
            #expect((b.stem.minY < b.head.y) == up)
            #expect(abs(beam[0].x - a.stem.minX) < 0.001 && abs(beam[1].x - b.stem.maxX) < 0.001)
            #expect(abs(beam[0].y - (up ? a.stem.minY : a.stem.maxY)) < 0.001)
            #expect(abs(beam[1].y - (up ? b.stem.minY : b.stem.maxY)) < 0.001)
            // Neither stem shorter than a single note's.
            #expect(a.stem.height >= 0.02 * 1800 * 3.4 - 0.001 && b.stem.height >= 0.02 * 1800 * 3.4 - 0.001)
        }
        #expect(Set(g.notes.map(\.step)).count >= 8)
        let measure = 0.36 * 1800
        let firstStaff = g.barlines.filter { $0.minY == g.barlines[0].minY }.map(\.midX)
        #expect(firstStaff.count >= 4)
        for (a, b) in zip(firstStaff, firstStaff.dropFirst()) {
            #expect(abs(b - a - measure) < 0.001)
        }
    }

    /// A head on a line is the same colour as a head in a space: the lines go behind
    /// the notes rather than through them.
    @Test func aHeadIsSolidOverItsLine() throws {
        var layer = Self.staff
        layer.fade = nil
        layer.playhead = nil
        layer.lineGap = 0.05
        var flat = Config.Background(angle: 90, stops: [.init(offset: 0, color: "#FEFAF2")])
        flat.layers = [layer]
        let with = Self.render(flat)
        let g = Compose.StaffGeometry(layer, width: 360, height: 240)
        func pixel(_ p: CGPoint) -> [Int] {
            let i = (Int(p.y) * 360 + Int(p.x)) * 4
            return (0..<3).map { Int(with[i + $0]) }
        }
        let inside = g.notes.filter {
            !$0.lit && !$0.beamed && $0.head.x > 8 && $0.head.x < 352 && $0.head.y > 8 && $0.head.y < 232
        }
        let onLine = try #require(inside.first { $0.step % 2 == 0 && (0...8).contains($0.step) })
        let inSpace = try #require(inside.first { $0.step % 2 != 0 && (1...7).contains($0.step) })
        #expect(zip(pixel(onLine.head), pixel(inSpace.head)).allSatisfy { abs($0 - $1) <= 2 })
    }

    @Test func rejectsAStaffItCannotDraw() throws {
        for edit: (inout Config.Layer) -> Void in [
            { $0.noteColor = "ink" },
            { $0.lit = "#E87" },
            { $0.noteOpacity = 1.2 },
            { $0.litOpacity = -0.1 },
            { $0.lineGap = 0 },
            { $0.lineGap = 0.0005 },
            { $0.measure = 1e-6 },
            { $0.measure = 0 },
            { $0.staffGap = -0.1 },
            { $0.playheadAt = 1.5 },
        ] {
            var layer = Self.staff
            edit(&layer)
            var config = try ConfigTests.decode()
            config.themes["dark"]!.background.layers = [layer]
            #expect(throws: AppShotError.self) { try config.validate() }
        }
        var config = try ConfigTests.decode()
        config.themes["dark"]!.background.layers = [Self.staff]
        #expect(throws: Never.self) { try config.validate() }
    }
}

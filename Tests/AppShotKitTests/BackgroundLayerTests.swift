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
}

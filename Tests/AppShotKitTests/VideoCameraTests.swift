import CoreGraphics
import Testing

@testable import AppShotKit

struct VideoCameraTests {
    static let stage = CGSize(width: 1000, height: 600)
    static let canvas = CGSize(width: 1920, height: 1080)
    static let box = CGRect(x: 54, y: 190, width: 1812, height: 836)

    static func still(_ preset: MotionPreset = .studio) -> MotionPreset {
        var p = preset
        p.drift = 0
        return p
    }

    static func camera(
        _ keys: [VideoCamera.Key], preset: MotionPreset = still(), entryAt: Double = -100,
        exitAt: Double? = nil
    ) -> VideoCamera {
        VideoCamera(
            preset: preset, stage: stage, canvas: canvas, box: box, keys: keys, entryAt: entryAt,
            exitAt: exitAt)
    }

    @Test func aFocusedRegionFillsTheBoxOnItsBindingAxis() {
        let region = CGRect(x: 100, y: 100, width: 600, height: 300)
        let cam = Self.camera([.init(time: 0, rect: region, fill: nil)])
        let placed = cam.placement(at: 10)
        let shown = placed.map(region)
        // fit = min(1812/1000, 836/600); height binds: 0.9 of the box's height.
        #expect(abs(shown.height - 0.9 * 836) < 0.5)
    }

    @Test func zoomStaysBetweenOneAndTheCap() {
        let tiny = Self.camera([.init(time: 0, rect: CGRect(x: 0, y: 0, width: 10, height: 10), fill: nil)])
        #expect(abs(tiny.state(at: 10).zoom - 2.6) < 1e-6)
        let huge = Self.camera([
            .init(time: 0, rect: CGRect(x: 0, y: 0, width: 5000, height: 5000), fill: nil)
        ])
        #expect(abs(huge.state(at: 10).zoom - 1) < 1e-6)
    }

    @Test func aZoomedWindowCoversTheCanvas() {
        let cam = Self.camera([.init(time: 0, rect: CGRect(x: 0, y: 0, width: 300, height: 200), fill: nil)])
        let rect = cam.placement(at: 10).rect
        #expect(rect.minX <= 0 && rect.minY <= 0)
        #expect(rect.maxX >= Self.canvas.width && rect.maxY >= Self.canvas.height)
    }

    @Test func aWindowAtRestStaysInsideTheCanvas() {
        let cam = Self.camera([.init(time: 0, rect: nil, fill: nil)])
        let rect = cam.placement(at: 10).rect
        #expect(rect.minX >= 0 && rect.minY >= 0)
        #expect(rect.maxX <= Self.canvas.width && rect.maxY <= Self.canvas.height)
    }

    @Test func theWindowNeverJumpsBetweenFrames() {
        let a = CGRect(x: 0, y: 0, width: 300, height: 200)
        let b = CGRect(x: 600, y: 350, width: 300, height: 200)
        let cam = Self.camera(
            [
                .init(time: 1, rect: a, fill: nil), .init(time: 3, rect: nil, fill: nil),
                .init(time: 5, rect: b, fill: nil),
            ], preset: .kinetic, entryAt: -100)
        var last = cam.placement(at: 0).rect
        for i in 1...(30 * 8) {
            let rect = cam.placement(at: Double(i) / 30).rect
            let moved = abs(rect.minX - last.minX) + abs(rect.minY - last.minY) + abs(rect.width - last.width)
            #expect(moved < Self.canvas.width * 0.5, "frame \(i) moved \(moved)px")
            last = rect
        }
    }

    @Test func driftIsContinuous() {
        let cam = Self.camera([], preset: .kinetic, entryAt: -100)
        for i in 0..<(30 * 12) {
            let a = cam.placement(at: Double(i) / 30).rect
            let b = cam.placement(at: Double(i + 1) / 30).rect
            #expect(abs(a.width - b.width) < 2)
        }
    }

    @Test func kineticRisesInAfterTheHookAndFallsOutForTheCard() {
        let cam = Self.camera([], preset: Self.still(.kinetic), entryAt: 1.25, exitAt: 10)
        #expect(cam.placement(at: 0.5).rect.minY >= Self.canvas.height)
        let settled = cam.placement(at: 5).rect
        #expect(abs(settled.midY - Self.box.midY) < 1)
        #expect(cam.placement(at: 10.5).rect.minY >= Self.canvas.height)
    }

    @Test func aZoomedWindowStaysBelowTheCanvasWhileTheHookIsOn() {
        let region = CGRect(x: 600, y: 350, width: 300, height: 200)
        let cam = Self.camera(
            [.init(time: 0, rect: region, fill: nil)], preset: Self.still(.kinetic), entryAt: 1.25)
        #expect(cam.placement(at: 0.5).rect.minY >= Self.canvas.height)
        let settled = cam.placement(at: 6).rect
        let framed = Self.camera([.init(time: 0, rect: region, fill: nil)], preset: Self.still(.kinetic))
            .placement(at: 6).rect
        #expect(abs(settled.minY - framed.minY) < 1 && abs(settled.minX - framed.minX) < 1)
    }

    @Test func aZoomedWindowFallsFullyOutForTheCard() {
        let region = CGRect(x: 600, y: 350, width: 300, height: 200)
        let cam = Self.camera(
            [.init(time: 0, rect: region, fill: nil)], preset: Self.still(.kinetic), entryAt: 1.25,
            exitAt: 10)
        #expect(cam.placement(at: 10.5).rect.minY >= Self.canvas.height)
    }

    @Test func studioFadesInAndShrinksAway() {
        let cam = Self.camera([], preset: Self.still(), entryAt: 0, exitAt: 10)
        #expect(cam.placement(at: 0).alpha == 0)
        #expect(cam.placement(at: 2).alpha == 1)
        #expect(cam.placement(at: 10.8).alpha == 0)
    }
}

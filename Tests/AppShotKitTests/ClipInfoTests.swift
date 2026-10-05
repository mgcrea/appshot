import Foundation
import Testing

@testable import AppShotKit

struct ClipInfoTests {
    static func info(screen: String = "browser", length: Double = 5, frames: Int = 120) -> ClipInfo {
        ClipInfo(
            screen: screen, stage: screen, appearance: "dark", length: length, crop: [10, 20, 400, 250],
            lightsPatch: .init(rect: [8, 4, 128, 48], recolored: true), frames: frames, maxFrameGap: 0.04,
            appshotVersion: "test", recordedAt: "2026-10-05T12:00:00Z")
    }

    @Test func roundTripsThroughItsFile() throws {
        let dir = try VideoMasterTests.dir()
        let url = ClipInfo.url(in: dir, screen: "browser", appearance: "dark")
        #expect(url.lastPathComponent == "browser~dark.clip.json")
        #expect(
            ClipInfo.movieURL(in: dir, screen: "browser", appearance: "dark").lastPathComponent
                == "browser~dark.mov")
        try Self.info().write(to: url)
        #expect(try ClipInfo.read(url) == Self.info())
        #expect(Self.info().size == CGSize(width: 400, height: 250))
        #expect(
            ClipInfo.lightsPatchURL(in: dir, screen: "browser", appearance: "dark").lastPathComponent
                == "browser~dark.lights.png")
    }

    /// A sidecar from before the patch: no `lightsPatch`, and the `trafficLights` field
    /// that compose no longer reads.
    @Test func readsASidecarWithoutALightsPatch() throws {
        let dir = try VideoMasterTests.dir()
        let url = dir.appending(path: "browser~dark.clip.json")
        try Data(
            """
            { "screen": "browser", "stage": "browser", "appearance": "dark", "length": 5,
              "crop": [10, 20, 400, 250], "trafficLights": { "origin": [0, 0], "scale": 2 },
              "frames": 120, "maxFrameGap": 0.04, "appshotVersion": "test",
              "recordedAt": "2026-10-05T12:00:00Z" }
            """.utf8
        ).write(to: url)
        var expected = Self.info()
        expected.lightsPatch = nil
        #expect(try ClipInfo.read(url) == expected)
    }

    @Test func aCropOfTheWrongShapeFailsNamingTheFile() throws {
        let dir = try VideoMasterTests.dir()
        let url = dir.appending(path: "browser~dark.clip.json")
        var info = Self.info()
        info.crop = [0, 0, 400]
        try info.write(to: url)
        #expect {
            _ = try ClipInfo.read(url)
        } throws: { error in
            guard case .invalidConfig(let at, let why)? = error as? AppShotError else { return false }
            return at == url && why.contains("crop")
        }
    }

    @Test(arguments: [[8, 4, 128], [8, 4, 0, 48]])
    func aLightsPatchRectOfTheWrongShapeFails(rect: [Double]) throws {
        let dir = try VideoMasterTests.dir()
        let url = dir.appending(path: "browser~dark.clip.json")
        var info = Self.info()
        info.lightsPatch = .init(rect: rect, recolored: false)
        try info.write(to: url)
        #expect {
            _ = try ClipInfo.read(url)
        } throws: { error in
            guard case .invalidConfig(let at, let why)? = error as? AppShotError else { return false }
            return at == url && why.contains("lights patch")
        }
    }
}

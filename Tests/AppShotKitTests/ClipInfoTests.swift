import Foundation
import Testing

@testable import AppShotKit

struct ClipInfoTests {
    static func info(screen: String = "browser", length: Double = 5, frames: Int = 120) -> ClipInfo {
        ClipInfo(
            screen: screen, stage: screen, appearance: "dark", length: length, crop: [10, 20, 400, 250],
            trafficLights: .init(origin: [0, 0], scale: 2), frames: frames, maxFrameGap: 0.04,
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

    @Test func aTrafficLightOriginOfTheWrongShapeFails() throws {
        let dir = try VideoMasterTests.dir()
        let url = dir.appending(path: "browser~dark.clip.json")
        var info = Self.info()
        info.trafficLights = .init(origin: [1], scale: 2)
        try info.write(to: url)
        #expect(throws: AppShotError.self) { _ = try ClipInfo.read(url) }
    }
}

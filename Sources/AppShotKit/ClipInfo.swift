import CoreGraphics
import Foundation

/// What `record --clips` wrote beside one clip: what was filmed, the crop that makes the
/// clip match its still, and how the take went.
public struct ClipInfo: Codable, Sendable, Equatable {
    /// Where the window's traffic lights are, so compose can recolor every frame as
    /// `capture --recolor-traffic-lights` recolors a still.
    public struct TrafficLights: Codable, Sendable, Equatable {
        /// The base window's top-left in crop pixels: x, y.
        public var origin: [Double]
        public var scale: Double
    }

    public var screen: String
    public var stage: String
    public var appearance: String
    /// Seconds recorded, from t = 0 to the moment the stream stopped. Not the last
    /// frame's time: ScreenCaptureKit sends nothing while the screen is still.
    public var length: Double
    /// The stage in master pixels, top-left origin: x, y, width, height.
    public var crop: [Double]
    /// Present only when the clip was recorded with `--recolor-traffic-lights` on a
    /// screen with chrome.
    public var trafficLights: TrafficLights?
    /// Distinct pictures filmed: frames that differ from the one before. Not every frame
    /// ScreenCaptureKit sent, since it sends one whenever anything on the display changes,
    /// so a still window on a Mac in use would count as moving.
    public var frames: Int
    public var maxFrameGap: Double
    public var appshotVersion: String
    public var recordedAt: String

    public var size: CGSize { CGSize(width: crop[2], height: crop[3]) }

    public static func name(screen: String, appearance: String) -> String { "\(screen)~\(appearance)" }

    public static func movieURL(in dir: URL, screen: String, appearance: String) -> URL {
        dir.appending(path: "\(name(screen: screen, appearance: appearance)).mov")
    }

    public static func url(in dir: URL, screen: String, appearance: String) -> URL {
        dir.appending(path: "\(name(screen: screen, appearance: appearance)).clip.json")
    }

    /// Checks the shapes JSON cannot, so a bad file fails here, named, rather than
    /// trapping mid-render.
    public static func read(_ url: URL) throws -> ClipInfo {
        let info: ClipInfo
        do {
            info = try JSONDecoder().decode(ClipInfo.self, from: Data(contentsOf: url))
        } catch {
            throw AppShotError.invalidConfig(url, "unreadable clip info: \(error)")
        }
        guard info.crop.count == 4, info.crop[2] > 0, info.crop[3] > 0 else {
            throw AppShotError.invalidConfig(
                url, "the clip's crop is not [x, y, width, height]: \(info.crop)")
        }
        if let lights = info.trafficLights, lights.origin.count != 2 {
            throw AppShotError.invalidConfig(url, "the traffic-light origin is not [x, y]: \(lights.origin)")
        }
        return info
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

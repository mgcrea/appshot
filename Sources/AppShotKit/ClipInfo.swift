import CoreGraphics
import Foundation

/// What `record --clips` wrote beside one clip: what was filmed, the crop that makes the
/// clip match its still, and how the take went.
public struct ClipInfo: Codable, Sendable, Equatable {
    /// The window's buttons as a screenshot taken just before filming shows them, which
    /// compose pastes over every frame. While the stream runs, macOS draws a "screen
    /// shared" capsule over the buttons of the window it films, in every frame; a
    /// screenshot never sees it. The patch is a still's own pixels, so a crossfade
    /// between the still and the clip leaves the corner alone.
    public struct LightsPatch: Codable, Sendable, Equatable {
        /// Where it goes, in crop pixels, top-left origin: x, y, width, height.
        public var rect: [Double]
        /// Whether it was cut under `--recolor-traffic-lights`, which repaints grey buttons
        /// as it repaints a still's.
        public var recolored: Bool
    }

    public var screen: String
    public var stage: String
    public var appearance: String
    /// Seconds recorded, from t = 0 to the moment the stream stopped. Not the last
    /// frame's time: ScreenCaptureKit sends a frame only when something on the display
    /// changes, so a quiet display can leave the last one well before the stop.
    public var length: Double
    /// The stage in master pixels, top-left origin: x, y, width, height.
    public var crop: [Double]
    /// On every screen with chrome whose buttons were found; the image is beside the
    /// clip, at `lightsPatchURL`.
    public var lightsPatch: LightsPatch?
    /// Distinct pictures filmed: frames that differ from the one before. Not every frame
    /// ScreenCaptureKit sent, since it sends one whenever anything on the display changes,
    /// so a still window on a Mac in use would count as moving.
    public var frames: Int
    /// The longest time between two of those pictures, the stretch from the last one to
    /// the stop included, so a clip that never moved shows about its whole length.
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

    public static func lightsPatchURL(in dir: URL, screen: String, appearance: String) -> URL {
        dir.appending(path: "\(name(screen: screen, appearance: appearance)).lights.png")
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
        if let patch = info.lightsPatch, patch.rect.count != 4 || patch.rect[2] <= 0 || patch.rect[3] <= 0 {
            throw AppShotError.invalidConfig(
                url, "the lights patch's rect is not [x, y, width, height]: \(patch.rect)")
        }
        return info
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

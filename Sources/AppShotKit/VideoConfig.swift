import Foundation

extension Config {
    /// One entry of `videos[]`: a scripted take of the app plus the copy laid over it.
    ///
    /// Lives in the same file as the screenshots for the same reason captions do: copy
    /// and pacing change without touching code or re-recording.
    public struct Video: Codable, Sendable {
        public var id: String
        /// The `-ScreenshotStage` the app launches into. Only `record` needs it;
        /// `compose video --from-stills` names a screen per beat instead.
        public var stage: String?
        public var duration: Double
        /// Seconds into the video for the poster frame. App Store Connect defaults to 5.
        public var poster: Double?
        public var outputs: VideoOutputs
        public var card: Card?
        public var beats: [Beat]
    }

    public struct VideoOutputs: Codable, Sendable {
        public var preview: Bool?
        /// `[[width, height], …]`, the shape the spec's examples use.
        public var promo: [[Int]]?
        /// A muted loop for the marketing site, rendered at the first promo size.
        public var website: Bool?

        public var wantsPreview: Bool { preview ?? false }
        public var wantsWebsite: Bool { website ?? false }
        public var promoSizes: [Size] {
            (promo ?? []).compactMap { $0.count == 2 ? Size(width: $0[0], height: $0[1]) : nil }
        }
    }

    /// The promo's closing card. Previews never show it: Apple allows only the app's
    /// own footage there.
    public struct Card: Codable, Sendable {
        public var title: String
        public var subtitle: String?
        /// A PNG, relative to the config file's directory.
        public var icon: String?
    }

    /// Ease the camera toward a reported element (`target`) or a fixed rect in stage
    /// pixels (`rect`, `[x, y, width, height]`, for `--from-stills` where no app reports
    /// anything). `scale: 1` returns to the whole stage and needs neither.
    public struct Zoom: Codable, Sendable, Equatable {
        public var target: String?
        public var rect: [Double]?
        public var scale: Double
    }

    public enum CueValue: Codable, Sendable, Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)

        /// String first, then number, then bool: JSONDecoder will not read `1` as a Bool,
        /// but trying Bool first would be the order that depends on that.
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                self = .string(s)
            } else if let n = try? c.decode(Double.self) {
                self = .number(n)
            } else {
                self = .bool(try c.decode(Bool.self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .number(let n): try c.encode(n)
            case .bool(let b): try c.encode(b)
            }
        }
    }

    public struct Beat: Codable, Sendable {
        public var at: Double
        public var cue: String?
        public var args: [String: CueValue]?
        public var caption: String?
        /// When the caption leaves. Absent ⇒ the next caption, the end card, or the end.
        public var until: Double?
        public var zoom: Zoom?
        public var endCard: Bool?
        /// `--from-stills` only: the `screens[]` capture to show from this beat on.
        public var screen: String?
    }

    public static let previewDuration: ClosedRange<Double> = 15...30

    /// The App Store preview canvas for a platform. iOS returns nil until iOS
    /// recording exists (spec phase 4), and validation says so.
    public static func previewSize(for platform: Platform) -> Size? {
        switch platform {
        case .mac: return Size(width: 1920, height: 1080)
        case .ios: return nil
        }
    }

    public func video(_ id: String) throws -> Video {
        guard let video = videos?.first(where: { $0.id == id }) else {
            throw AppShotError.unknownVideo(id, known: (videos ?? []).map(\.id))
        }
        return video
    }

    func validateVideos() throws {
        var seen = Set<String>()
        for video in videos ?? [] {
            func fail(_ why: String) -> AppShotError {
                .invalidVideo(id: video.id, reason: why)
            }

            guard
                video.id.range(
                    of: #"^[a-z0-9][a-z0-9-]*$"#,
                    options: .regularExpression
                ) != nil
            else {
                throw fail(
                    "the id becomes a filename: use lowercase letters, digits and -")
            }
            guard seen.insert(video.id).inserted else {
                throw fail("the id is used twice")
            }
            guard video.duration > 0 else { throw fail("duration must be positive") }
            if let poster = video.poster, !(0..<video.duration).contains(poster) {
                throw fail("poster \(poster)s is outside 0..<\(video.duration)s")
            }

            var last = 0.0
            for (i, beat) in video.beats.enumerated() {
                guard (0..<video.duration).contains(beat.at) else {
                    throw fail("beat \(i) at \(beat.at)s is outside 0..<\(video.duration)s")
                }
                guard beat.at >= last else {
                    throw fail(
                        "beat \(i) at \(beat.at)s comes before the one above it; "
                            + "keep beats in time order")
                }
                last = beat.at
                if let until = beat.until {
                    guard beat.caption != nil else {
                        throw fail("beat \(i) has `until` but no caption")
                    }
                    guard until > beat.at, until <= video.duration else {
                        throw fail(
                            "beat \(i) until \(until)s must be after its `at` and "
                                + "within the duration")
                    }
                }
                if let zoom = beat.zoom {
                    guard (1...4).contains(zoom.scale) else {
                        throw fail("beat \(i) zoom scale \(zoom.scale) is outside 1...4")
                    }
                    guard zoom.scale == 1 || (zoom.target == nil) != (zoom.rect == nil) else {
                        throw fail("beat \(i) zoom needs exactly one of target or rect")
                    }
                    if let rect = zoom.rect,
                        rect.count != 4 || rect[2] <= 0 || rect[3] <= 0
                    {
                        throw fail(
                            "beat \(i) zoom rect must be [x, y, width, height] "
                                + "with a positive size")
                    }
                }
                if let screen = beat.screen, !capturedScreenIDs.contains(screen) {
                    throw fail(
                        "beat \(i) names screen \"\(screen)\", which screens[] "
                            + "does not capture")
                }
            }

            let cards = video.beats.filter { $0.endCard == true }.count
            guard cards <= 1 else { throw fail("only one beat may show the end card") }
            if cards == 1, video.card == nil {
                throw fail("a beat shows the end card but the video has no card")
            }

            for raw in video.outputs.promo ?? [] {
                guard raw.count == 2, raw[0] > 0, raw[1] > 0 else {
                    throw fail("promo sizes are [width, height] pairs of positive integers")
                }
                guard raw[0] % 2 == 0, raw[1] % 2 == 0 else {
                    throw fail(
                        "promo size \(raw[0])x\(raw[1]) has an odd side; "
                            + "H.264 needs even dimensions")
                }
            }
            if video.outputs.wantsPreview {
                guard Config.previewSize(for: resolvedPlatform) != nil else {
                    throw fail(
                        "App Store previews for iOS arrive with iOS recording; "
                            + "set preview to false for now")
                }
                guard Config.previewDuration.contains(video.duration) else {
                    throw fail(
                        "an App Store preview must last 15-30s, this one is "
                            + "\(video.duration)s")
                }
            }
            if video.outputs.wantsWebsite, video.outputs.promoSizes.isEmpty {
                throw fail(
                    "the website video is rendered at the first promo size; "
                        + "add one to promo")
            }
            guard video.outputs.wantsPreview || !video.outputs.promoSizes.isEmpty else {
                throw fail("outputs asks for nothing: set preview, promo or both")
            }
        }
    }
}

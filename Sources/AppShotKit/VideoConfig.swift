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
        /// The motion preset; `kinetic` when absent. `compose video --motion` overrides it.
        public var motion: String?
        /// The opening line. Full-frame in a preset with a hook card, then the first
        /// caption until the next caption beat; just that caption in other presets.
        public var hook: String?
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
        /// A call to action under the subtitle, drawn as a pill.
        public var cta: String?
    }

    /// `zoom` became `focus` before videos shipped. The key is still read so validation
    /// can say so instead of silently ignoring it; its content is not.
    public struct Renamed: Codable, Sendable, Equatable {
        public init() {}
        public init(from decoder: Decoder) throws {}
        public func encode(to encoder: Encoder) throws {}
    }

    /// A part of the stage: an element the app reported (`target`) or stage pixels
    /// (`rect`, `[x, y, width, height]`, for `--from-stills`, where nothing reports).
    public struct Region: Codable, Sendable, Equatable {
        public var target: String?
        public var rect: [Double]?

        public init(target: String?, rect: [Double]?) {
            self.target = target
            self.rect = rect
        }
    }

    /// Frame a region, or the whole window with `"home"`. The zoom is computed from the
    /// region; `fill` (0.3...1) loosens or tightens the preset's framing.
    public enum Focus: Codable, Sendable, Equatable {
        case home
        case region(Region, fill: Double?)

        private enum Keys: String, CodingKey { case target, rect, fill }

        public init(from decoder: Decoder) throws {
            if let word = try? decoder.singleValueContainer().decode(String.self) {
                guard word == "home" else {
                    throw DecodingError.dataCorrupted(
                        .init(
                            codingPath: decoder.codingPath,
                            debugDescription:
                                "focus is \"home\" or { \"rect\" | \"target\" }, not \"\(word)\""))
                }
                self = .home
                return
            }
            let c = try decoder.container(keyedBy: Keys.self)
            self = .region(
                Region(
                    target: try c.decodeIfPresent(String.self, forKey: .target),
                    rect: try c.decodeIfPresent([Double].self, forKey: .rect)),
                fill: try c.decodeIfPresent(Double.self, forKey: .fill))
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .home:
                var c = encoder.singleValueContainer()
                try c.encode("home")
            case .region(let region, let fill):
                var c = encoder.container(keyedBy: Keys.self)
                try c.encodeIfPresent(region.target, forKey: .target)
                try c.encodeIfPresent(region.rect, forKey: .rect)
                try c.encodeIfPresent(fill, forKey: .fill)
            }
        }
    }

    /// A region that matters until `until`, in seconds from the start of the video.
    public struct Emphasis: Codable, Sendable, Equatable {
        public var target: String?
        public var rect: [Double]?
        public var until: Double
    }

    /// `--from-stills` only: where the drawn pointer goes, arriving at the beat's time.
    public struct PointerMove: Codable, Sendable, Equatable {
        public var point: [Double]?
        public var rect: [Double]?
        public var click: Bool?
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
        public var zoom: Renamed?
        public var endCard: Bool?
        /// `--from-stills` only: the `screens[]` capture to show from this beat on.
        public var screen: String?
        public var focus: Focus?
        public var spotlight: Emphasis?
        public var pop: Emphasis?
        public var pointer: PointerMove?
        /// `--from-stills` only, on a `screen` beat: this region of the new capture is a
        /// sheet, and springs up over the window instead of crossfading.
        public var present: [Double]?

        public init(
            at: Double, cue: String? = nil, args: [String: CueValue]? = nil, caption: String? = nil,
            until: Double? = nil, endCard: Bool? = nil, screen: String? = nil,
            focus: Focus? = nil, spotlight: Emphasis? = nil, pop: Emphasis? = nil,
            pointer: PointerMove? = nil, present: [Double]? = nil
        ) {
            self.at = at
            self.cue = cue
            self.args = args
            self.caption = caption
            self.until = until
            self.endCard = endCard
            self.screen = screen
            self.focus = focus
            self.spotlight = spotlight
            self.pop = pop
            self.pointer = pointer
            self.present = present
        }
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
            if let motion = video.motion, MotionPreset.named(motion) == nil {
                throw AppShotError.unknownMotion(
                    video: video.id, name: motion, known: MotionPreset.all.map(\.name))
            }
            if let hook = video.hook, KineticText.tokens(hook) == nil {
                throw fail("the hook has an unclosed *")
            }
            if let title = video.card?.title, KineticText.tokens(title) == nil {
                throw fail("the card title has an unclosed *")
            }
            func checkRect(_ rect: [Double], _ what: String) throws {
                guard rect.count == 4, rect[2] > 0, rect[3] > 0 else {
                    throw fail("\(what) rect must be [x, y, width, height] with a positive size")
                }
            }
            func checkRegion(_ target: String?, _ rect: [Double]?, _ what: String) throws {
                guard (target == nil) != (rect == nil) else {
                    throw fail("\(what) needs exactly one of target or rect")
                }
                if let rect { try checkRect(rect, what) }
            }

            var last = 0.0
            for (i, beat) in video.beats.enumerated() {
                if beat.zoom != nil { throw AppShotError.zoomRenamed(video: video.id, beat: i) }
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
                if let caption = beat.caption {
                    guard KineticText.tokens(caption) != nil else {
                        throw fail("beat \(i) caption has an unclosed *")
                    }
                    if video.hook != nil, beat.at < MotionPreset.hookDuration {
                        throw fail(
                            "beat \(i) caption at \(beat.at)s starts under the hook, which holds "
                                + "the first \(MotionPreset.hookDuration)s")
                    }
                }
                if case .region(let region, let fill)? = beat.focus {
                    try checkRegion(region.target, region.rect, "beat \(i) focus")
                    if let fill, !(0.3...1).contains(fill) {
                        throw fail("beat \(i) focus fill \(fill) is outside 0.3...1")
                    }
                }
                for (key, emphasis) in [("spotlight", beat.spotlight), ("pop", beat.pop)] {
                    guard let emphasis else { continue }
                    try checkRegion(emphasis.target, emphasis.rect, "beat \(i) \(key)")
                    guard emphasis.until > beat.at, emphasis.until <= video.duration else {
                        throw fail(
                            "beat \(i) \(key) until \(emphasis.until)s must be after its `at` "
                                + "and within the duration")
                    }
                }
                if let pointer = beat.pointer {
                    guard (pointer.point == nil) != (pointer.rect == nil) else {
                        throw fail("beat \(i) pointer needs exactly one of point or rect")
                    }
                    if let point = pointer.point, point.count != 2 {
                        throw fail("beat \(i) pointer point must be [x, y]")
                    }
                    if let rect = pointer.rect { try checkRect(rect, "beat \(i) pointer") }
                }
                if let present = beat.present {
                    guard beat.screen != nil else {
                        throw fail(
                            "beat \(i) has `present` but no screen: only a cut to a capture "
                                + "can present a sheet")
                    }
                    try checkRect(present, "beat \(i) present")
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

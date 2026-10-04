import Foundation
import Testing

@testable import AppShotKit

struct VideoConfigTests {
    /// ConfigTests' fixture with a `videos` array spliced in before `screens`.
    static func config(videos: String) throws -> Config {
        let json = ConfigTests.json.replacingOccurrences(
            of: "\"screens\": [",
            with: "\"videos\": \(videos),\n\"screens\": [")
        return try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    static let valid = """
        [{ "id": "intro", "stage": "browser", "duration": 20, "poster": 5,
           "outputs": { "preview": true, "promo": [[1920, 1080], [1080, 1080]], "website": true },
           "card": { "title": "D1", "subtitle": "d1.example" },
           "beats": [
             { "at": 0, "caption": "Your databases", "screen": "browser" },
             { "at": 1.5, "cue": "pointer.click", "args": { "target": "row-2", "n": 2, "on": true } },
             { "at": 4, "focus": { "target": "row-2" } },
             { "at": 16, "endCard": true }
           ] }]
        """

    @Test func existingConfigsStillValidate() throws {
        let config = try ConfigTests.decode()
        #expect(config.videos == nil)
        try config.validate()
    }

    @Test func decodesAVideo() throws {
        let config = try Self.config(videos: Self.valid)
        try config.validate()
        let video = try config.video("intro")
        #expect(video.beats.count == 4)
        #expect(
            video.outputs.promoSizes == [
                Config.Size(width: 1920, height: 1080),
                Config.Size(width: 1080, height: 1080),
            ])
        #expect(video.beats[1].args?["n"] == .number(2))
        #expect(video.beats[1].args?["on"] == .bool(true))
        #expect(video.beats[1].args?["target"] == .string("row-2"))
    }

    @Test func zoomWasRenamedToFocus() throws {
        let config = try Self.config(
            videos:
                #"[{"id":"x","duration":20,"outputs":{"promo":[[100,100]]},"beats":[{"at":1,"zoom":{"scale":2}}]}]"#
        )
        #expect {
            try config.validate()
        } throws: { error in
            guard case .zoomRenamed(let video, let beat) = error as? AppShotError else { return false }
            return video == "x" && beat == 0
                && (error as? AppShotError)?.description.contains("`focus`") == true
        }
    }

    @Test(arguments: [
        (#"[{"id":"x","duration":20,"outputs":{"promo":[[1079,1080]]},"beats":[]}]"#, "odd side"),
        (#"[{"id":"x","duration":10,"outputs":{"preview":true},"beats":[]}]"#, "15-30s"),
        (
            #"[{"id":"x","duration":20,"outputs":{"promo":[[100,100]]},"beats":[{"at":5},{"at":2}]}]"#,
            "time order"
        ),
        (#"[{"id":"x","duration":20,"outputs":{"promo":[[100,100]]},"beats":[{"at":20}]}]"#, "outside"),
        (
            #"[{"id":"x","duration":20,"outputs":{"promo":[[100,100]]},"beats":[{"at":1,"endCard":true}]}]"#,
            "no card"
        ),
        (
            #"[{"id":"x","duration":20,"outputs":{"promo":[[100,100]]},"beats":[{"at":1,"screen":"nope"}]}]"#,
            "does not capture"
        ),
        (#"[{"id":"X Y","duration":20,"outputs":{"promo":[[100,100]]},"beats":[]}]"#, "filename"),
        (#"[{"id":"x","duration":20,"outputs":{},"beats":[]}]"#, "asks for nothing"),
        (#"[{"id":"x","duration":20,"outputs":{"website":true},"beats":[]}]"#, "website video"),
    ])
    func rejects(json: String, reason: String) throws {
        let config = try Self.config(videos: json)
        #expect {
            try config.validate()
        } throws: { error in
            guard case AppShotError.invalidVideo(_, let why) = error else { return false }
            return why.contains(reason)
        }
    }

    @Test func unknownVideoNamesTheKnownOnes() throws {
        let config = try Self.config(videos: Self.valid)
        #expect(throws: AppShotError.self) { try config.video("outro") }
    }

    static let motion = """
        [{ "id": "promo", "duration": 20, "motion": "studio", "hook": "Your folder is a *mess*.",
           "outputs": { "promo": [[1200, 1200]] },
           "card": { "title": "Pochette", "subtitle": "Your music, as files.", "cta": "On the Mac App Store" },
           "beats": [
             { "at": 0, "screen": "browser" },
             { "at": 0.9, "focus": { "rect": [20, 426, 580, 516], "fill": 0.8 } },
             { "at": 1.6, "spotlight": { "rect": [20, 426, 580, 516], "until": 3.9 } },
             { "at": 3.4, "pointer": { "point": [1250, 760] } },
             { "at": 4.0, "focus": "home" },
             { "at": 4.8, "pointer": { "rect": [1460, 30, 44, 44], "click": true } },
             { "at": 5.0, "screen": "paywall", "present": [600, 275, 1358, 1047],
               "caption": "Rename every file in *one go*." },
             { "at": 7.6, "pop": { "rect": [640, 1040, 640, 78], "until": 10.2 } },
             { "at": 15.8, "endCard": true }
           ] }]
        """

    @Test func decodesTheMotionKeys() throws {
        let config = try Self.config(videos: Self.motion)
        try config.validate()
        let video = try config.video("promo")
        #expect(video.motion == "studio")
        #expect(video.hook == "Your folder is a *mess*.")
        #expect(video.card?.cta == "On the Mac App Store")
        #expect(video.beats[1].focus == .region(.init(target: nil, rect: [20, 426, 580, 516]), fill: 0.8))
        #expect(video.beats[4].focus == .home)
        #expect(video.beats[2].spotlight?.until == 3.9)
        #expect(video.beats[5].pointer?.click == true)
        #expect(video.beats[6].present == [600, 275, 1358, 1047])
        #expect(video.beats[7].pop?.rect == [640, 1040, 640, 78])
    }

    @Test func anUnknownMotionNamesTheKnownOnes() throws {
        let config = try Self.config(
            videos:
                #"[{"id":"x","duration":20,"motion":"keynote","outputs":{"promo":[[100,100]]},"beats":[]}]"#)
        #expect {
            try config.validate()
        } throws: { error in
            guard case .unknownMotion(let video, let name, let known) = error as? AppShotError else {
                return false
            }
            return video == "x" && name == "keynote" && known == ["kinetic", "studio"]
        }
    }

    @Test(arguments: [
        (#"{"at":1,"caption":"a *b"}"#, "unclosed"),
        (#"{"at":1,"caption":"under the hook"}"#, "starts under the hook"),
        (#"{"at":2,"focus":{"rect":[0,0,10,10],"target":"t"}}"#, "exactly one of target or rect"),
        (#"{"at":2,"focus":{"rect":[0,0,10]}}"#, "focus rect must be"),
        (#"{"at":2,"focus":{"rect":[0,0,10,10],"fill":0.2}}"#, "outside 0.3...1"),
        (#"{"at":2,"spotlight":{"rect":[0,0,10,10],"until":2}}"#, "spotlight until"),
        (#"{"at":2,"pop":{"target":"t","until":30}}"#, "pop until"),
        (#"{"at":2,"pop":{"until":3}}"#, "exactly one of target or rect"),
        (#"{"at":2,"pointer":{"point":[1,2],"rect":[0,0,1,1]}}"#, "exactly one of point or rect"),
        (#"{"at":2,"pointer":{"point":[1]}}"#, "point must be [x, y]"),
        (#"{"at":2,"present":[0,0,10,10]}"#, "but no screen"),
        (#"{"at":2,"screen":"browser","present":[0,0,0,10]}"#, "present rect must be"),
    ])
    func rejectsABadMotionBeat(beat: String, reason: String) throws {
        let config = try Self.config(
            videos: """
                [{"id":"x","duration":20,"hook":"Hello there","outputs":{"promo":[[100,100]]},
                  "beats":[{"at":0,"screen":"browser"},\(beat)]}]
                """)
        #expect {
            try config.validate()
        } throws: { error in
            guard case .invalidVideo(_, let why) = error as? AppShotError else { return false }
            return why.contains(reason)
        }
    }

    @Test func anUnclosedMarkInTheHookOrCardIsRejected() throws {
        for (hook, title) in [("a *b", "T"), ("ok", "*T")] {
            let config = try Self.config(
                videos: """
                    [{"id":"x","duration":20,"hook":"\(hook)","card":{"title":"\(title)"},
                      "outputs":{"promo":[[100,100]]},"beats":[]}]
                    """)
            #expect(throws: AppShotError.self) { try config.validate() }
        }
    }
}

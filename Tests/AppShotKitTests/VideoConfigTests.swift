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
             { "at": 4, "zoom": { "target": "row-2", "scale": 1.6 } },
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
            #"[{"id":"x","duration":20,"outputs":{"promo":[[100,100]]},"beats":[{"at":1,"zoom":{"scale":2}}]}]"#,
            "exactly one of target or rect"
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
}

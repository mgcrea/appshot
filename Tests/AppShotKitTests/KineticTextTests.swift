import CoreGraphics
import CoreText
import Testing

@testable import AppShotKit

struct KineticTextTests {
    @Test func anAccentCoversTheMarkedWordsOnly() throws {
        let tokens = try #require(KineticText.tokens("Your music folder is a *mess*."))
        #expect(tokens.map(\.text) == ["Your", "music", "folder", "is", "a", "mess."])
        #expect(tokens.map(\.accent) == [false, false, false, false, false, true])
    }

    @Test func anAccentCanSpanSeveralWords() throws {
        let tokens = try #require(KineticText.tokens("Then file it all by *artist and album*."))
        #expect(tokens.filter(\.accent).map(\.text) == ["artist", "and", "album."])
    }

    @Test func anOpenMarkIsRejected() {
        #expect(KineticText.tokens("a *b c") == nil)
        #expect(KineticText.tokens("no marks") != nil)
    }

    @Test func plainDropsTheMarks() {
        #expect(KineticText.plain("Rename every file in *one go*.") == "Rename every file in one go.")
    }

    @Test func layoutWrapsInsideTheWidth() throws {
        let font = try Text.font(stack: "Helvetica", weight: 700, size: 40)
        let white = CGColor(gray: 1, alpha: 1)
        let tokens = try #require(KineticText.tokens("Then file it all by *artist and album* every time"))
        let layout = KineticText.layout(tokens, font: font, color: white, accent: white, maxWidth: 300)
        #expect(layout.rows > 1)
        #expect(layout.rowWidths.allSatisfy { $0 <= 300 })
        #expect(layout.words.count == tokens.count)
        #expect(layout.words.allSatisfy { $0.x + $0.width <= 300 + 0.5 })
    }

    @Test func wordsEnterInOrderAndSettle() {
        let spring = MotionPreset.kinetic.wordSpring
        #expect(KineticText.entrance(age: -0.1, index: 0, stagger: 0.06, spring: spring).alpha == 0)
        let first = KineticText.entrance(age: 0.1, index: 0, stagger: 0.06, spring: spring)
        let third = KineticText.entrance(age: 0.1, index: 2, stagger: 0.06, spring: spring)
        #expect(first.alpha > third.alpha)
        let settled = KineticText.entrance(age: 5, index: 3, stagger: 0.06, spring: spring)
        #expect(settled.alpha == 1 && abs(settled.drop) < 0.001)
    }
}

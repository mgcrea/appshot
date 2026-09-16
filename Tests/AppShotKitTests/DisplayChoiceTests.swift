import CoreGraphics
import Testing

@testable import AppShotKit

/// The rule behind `--capture-display`. Every case here is a way a run could silently
/// change what it photographs, which is why the fallback is always "pass nothing".
@Suite("display choice")
struct DisplayChoiceTests {

    private func display(
        _ id: CGDirectDisplayID, builtin: Bool = false, scale: CGFloat = 2, main: Bool = false
    ) -> DisplayChoice.Display {
        .init(id: id, isBuiltin: builtin, scale: scale, isMain: main)
    }

    @Test("main passes nothing, so the app keeps deciding")
    func mainIsSilent() {
        let displays = [display(1, main: true), display(2, builtin: true)]
        #expect(DisplayChoice.main.resolve(among: displays) == nil)
    }

    @Test("a single display is never overridden")
    func singleDisplay() {
        let only = [display(1, builtin: true, main: true)]
        for choice in DisplayChoice.allCases {
            #expect(choice.resolve(among: only) == nil)
        }
    }

    @Test("secondary picks the display that is not holding the key window")
    func secondary() {
        let displays = [display(1, main: true), display(2, builtin: true)]
        #expect(DisplayChoice.secondary.resolve(among: displays) == 2)
    }

    @Test("builtin picks the laptop panel when the work is on the external one")
    func builtinBesideExternal() {
        // The common desk setup: an external display in front of you, lid open beside it.
        let displays = [display(1, main: true), display(2, builtin: true)]
        #expect(DisplayChoice.builtin.resolve(among: displays) == 2)
        #expect(DisplayChoice.external.resolve(among: displays) == nil)
    }

    @Test("external picks the spare monitor when the work is on the laptop")
    func externalBesideBuiltin() {
        let displays = [display(1, builtin: true, main: true), display(2)]
        #expect(DisplayChoice.external.resolve(among: displays) == 2)
        #expect(DisplayChoice.builtin.resolve(among: displays) == nil)
    }

    /// The guard that matters. A 1x display beside a 2x one halves every captured
    /// dimension, so the gate fails on every screen at once and nothing in the output says
    /// why. Declining to move is always the safer answer.
    @Test("a display with a different backing scale is refused")
    func refusesScaleChange() {
        let displays = [display(1, main: true), display(2, builtin: true, scale: 1)]
        #expect(DisplayChoice.secondary.resolve(among: displays) == nil)
        #expect(DisplayChoice.builtin.resolve(among: displays) == nil)
    }

    /// Laptop plus two monitors, working on one of them. Searching the whole list and
    /// rejecting a main-display hit afterwards looks equivalent to excluding main up front
    /// and is not: it finds the monitor in use, rejects it, and gives up — leaving the idle
    /// monitor unused, which is the display that was asked for.
    @Test("external skips the monitor being worked on and takes the idle one")
    func externalWithTwoMonitors() {
        let displays = [
            display(1, builtin: true), display(2, main: true), display(3),
        ]
        #expect(DisplayChoice.external.resolve(among: displays) == 3)
        #expect(DisplayChoice.builtin.resolve(among: displays) == 1)
    }

    @Test("a request for the display already in use passes nothing")
    func neverResolvesToMain() {
        let onlyMainIsBuiltin = [display(1, builtin: true, main: true), display(2)]
        #expect(DisplayChoice.builtin.resolve(among: onlyMainIsBuiltin) == nil)
        #expect(DisplayChoice.external.resolve(among: onlyMainIsBuiltin) == 2)
    }
}

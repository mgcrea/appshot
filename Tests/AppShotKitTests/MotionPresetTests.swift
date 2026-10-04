import Testing

@testable import AppShotKit

struct MotionPresetTests {
    @Test(arguments: [MotionPreset.kinetic.camera, MotionPreset.studio.camera, MotionPreset.kinetic.sheet])
    func aSpringStartsAtZeroAndSettlesAtOne(spring: Spring) {
        #expect(spring.value(-1) == 0)
        #expect(spring.value(0) == 0)
        #expect(abs(spring.value(spring.response * 5) - 1) < 0.001)
        #expect(spring.value(.infinity) == 1)
    }

    @Test func aCriticallyDampedSpringNeverOvershoots() {
        let spring = MotionPreset.studio.camera
        #expect(stride(from: 0.0, through: 5, by: 0.005).allSatisfy { spring.value($0) <= 1 })
    }

    @Test func kineticsCameraOvershoots() {
        let spring = MotionPreset.kinetic.camera
        #expect(stride(from: 0.0, through: 5, by: 0.005).contains { spring.value($0) > 1.001 })
    }

    @Test func easingIsClampedToItsRange() {
        #expect(Ease.smooth(-1) == 0 && Ease.smooth(2) == 1 && Ease.smooth(0.5) == 0.5)
        #expect(Ease.out(-1) == 0 && Ease.out(2) == 1 && Ease.out(0.5) > 0.5)
    }

    @Test func presetsAreFoundByName() {
        #expect(MotionPreset.named("kinetic") == .kinetic)
        #expect(MotionPreset.named("studio") == .studio)
        #expect(MotionPreset.named("keynote") == nil)
        #expect(MotionPreset.all.map(\.name) == ["kinetic", "studio"])
        #expect(MotionPreset.named(MotionPreset.defaultName) == .kinetic)
    }
}

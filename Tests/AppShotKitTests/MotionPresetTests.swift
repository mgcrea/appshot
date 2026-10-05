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
        #expect(MotionPreset.named("calm") == .calm)
        #expect(MotionPreset.named("keynote") == nil)
        #expect(MotionPreset.all.map(\.name) == ["kinetic", "studio", "calm"])
        #expect(MotionPreset.named(MotionPreset.defaultName) == .kinetic)
    }

    @Test func calmIsGentlerThanStudioEverywhereItCanBe() {
        let calm = MotionPreset.calm
        let studio = MotionPreset.studio
        #expect(stride(from: 0.0, through: 6, by: 0.005).allSatisfy { calm.camera.value($0) <= 1 })
        #expect(calm.camera.response > studio.camera.response)
        #expect(calm.zoomCap < studio.zoomCap)
        #expect(calm.drift < studio.drift)
        #expect(calm.spotlightDim < studio.spotlightDim)
        #expect(calm.swing == 0)
        #expect(!calm.glow && !calm.hookCard)
        #expect(calm.entry == .fadeIn && calm.card == .fade)
    }
}

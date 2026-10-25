import Testing

@testable import AppShotKit

struct MotionPresetTests {
    static func spring(_ move: CameraMove) -> Spring {
        guard case .spring(let spring) = move else { fatalError("\(move) is not a spring") }
        return spring
    }

    @Test(arguments: [
        Self.spring(MotionPreset.kinetic.camera), Self.spring(MotionPreset.studio.camera), MotionPreset.kinetic.sheet,
    ])
    func aSpringStartsAtZeroAndSettlesAtOne(spring: Spring) {
        #expect(spring.value(-1) == 0)
        #expect(spring.value(0) == 0)
        #expect(abs(spring.value(spring.response * 5) - 1) < 0.001)
        #expect(spring.value(.infinity) == 1)
    }

    @Test func aCriticallyDampedSpringNeverOvershoots() {
        let spring = Self.spring(MotionPreset.studio.camera)
        #expect(stride(from: 0.0, through: 5, by: 0.005).allSatisfy { spring.value($0) <= 1 })
    }

    @Test func kineticsCameraOvershoots() {
        let spring = Self.spring(MotionPreset.kinetic.camera)
        #expect(stride(from: 0.0, through: 5, by: 0.005).contains { spring.value($0) > 1.001 })
    }

    @Test func easingIsClampedToItsRange() {
        #expect(Ease.smooth(-1) == 0 && Ease.smooth(2) == 1 && Ease.smooth(0.5) == 0.5)
        #expect(Ease.out(-1) == 0 && Ease.out(2) == 1 && Ease.out(0.5) > 0.5)
        #expect(Ease.smoother(-1) == 0 && Ease.smoother(2) == 1 && Ease.smoother(0.5) == 0.5)
    }

    @Test func aGlideLeavesAndLandsGently() {
        let glide = CameraMove.glide(2.4)
        #expect(glide.value(-1) == 0 && glide.value(0) == 0)
        #expect(glide.value(2.4) == 1 && glide.value(10) == 1)
        #expect(abs(glide.value(1.2) - 0.5) < 1e-9)
        // A critically damped spring of the same length is past half way by a third of it;
        // a glide has barely left by a sixth.
        #expect(glide.value(0.4) < 0.05)
        #expect(CameraMove.spring(Spring(response: 2.4, damping: 1)).value(0.8) > 0.5)
        #expect(stride(from: 0.0, through: 3, by: 0.005).allSatisfy { glide.value($0) <= 1 })
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
        #expect(calm.camera.settle > studio.camera.settle)
        #expect(calm.camera == .glide(calm.camera.settle))
        #expect(calm.zoomCap < studio.zoomCap)
        #expect(calm.drift == 0)
        #expect(calm.spotlightDim < studio.spotlightDim)
        #expect(calm.swing == 0)
        #expect(!calm.glow && !calm.hookCard)
        #expect(calm.entry == .fadeIn && calm.card == .fade)
    }
}

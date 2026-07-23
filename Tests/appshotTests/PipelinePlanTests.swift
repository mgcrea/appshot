import Testing

@testable import AppShotKit
@testable import appshot

/// `run` used to drive its legs by constructing `Check()`/`Both()` and assigning
/// properties one at a time, which silently skipped any option the caller forgot —
/// ArgumentParser stores a declared default as an unparsed definition, so reading an
/// unassigned one exits(1). That killed the whole chain from the first commit.
///
/// Neither obvious test shape can catch it. End-to-end is out: `run`'s first leg needs a
/// real .app, Screen Recording permission and ~90s of exclusive pointer control, so it
/// never reaches the crash in CI. Constructing a command and calling `run()` is also out:
/// `configurationFailure` calls exit(1), which takes the test binary down with no
/// attribution rather than failing a case.
///
/// So these assert on the plan as a *value*, before anything runs. Note what actually
/// prevents recurrence: the no-default memberwise inits on `Pipeline`'s option structs
/// make an omission a compile error. These cover the rest — wrong wiring, drifted defaults.
struct PipelinePlanTests {
    static func parseRun(_ extra: [String] = []) throws -> Run {
        try Run.parse(["--app", "/tmp/X.app", "--screens", "home:home"] + extra)
    }

    @Test("run carries every knob its legs read")
    func runPlanCarriesEveryKnob() throws {
        // --website-out, or the site leg is legitimately nil and proves nothing.
        let plan = try Self.parseRun(["--website-out", "/tmp/site"])
            .plan(appearances: ["dark", "light"])

        // The three properties that were actually unset, and the crash each caused.
        #expect(plan.check.tolerance == Defaults.tolerance)
        #expect(plan.compose.website?.appearance == Defaults.appearance)
        #expect(plan.compose.website?.maxWidth == Defaults.maxWidth)

        #expect(plan.capture.appearances == ["dark", "light"])
        // capture must write where check reads, or the gate compares an empty directory.
        #expect(plan.check.paths.source == plan.capture.out)

        // The settle knobs reach the capture leg with the documented defaults — a
        // drifted one here is a --help that lies about how long a run will take.
        #expect(plan.capture.settle == Defaults.settle)
        #expect(plan.capture.settleMax == Defaults.settleMax)
        #expect(plan.capture.timings == false)

        // The concurrency and readiness knobs, same reasoning: `run` re-declares them,
        // so a default that drifts here is a `--help` that lies about what you get.
        #expect(plan.capture.wait == false)
        #expect(plan.capture.waitTimeout == CaptureLock.defaultWaitTimeout)
        #expect(plan.capture.foregroundLaunch == false)
        #expect(plan.capture.readyFile == false)
        #expect(plan.capture.readyArg == Defaults.readyArg)
        #expect(plan.check.requireManifest == false)
        // `run` composes straight after the gate, so its output is a build log rather
        // than a verdict to parse. JSON belongs to `appshot check`.
        #expect(plan.check.json == false)
    }

    @Test("the concurrency and readiness flags reach the capture leg")
    func concurrencyAndReadinessReachCapture() throws {
        let plan =
            try Self
            .parseRun([
                "--wait", "--wait-timeout", "42",
                "--foreground-launch",
                // `=`, because the value starts with a `-` and ArgumentParser would
                // otherwise read it as a flag of its own — the same trap --extra-args
                // carries.
                "--ready-file", "--ready-arg=-Ready",
                "--require-manifest",
            ])
            .plan(appearances: ["dark"])

        #expect(plan.capture.wait)
        #expect(plan.capture.waitTimeout == 42)
        #expect(plan.capture.foregroundLaunch)
        #expect(plan.capture.readyFile)
        #expect(plan.capture.readyArg == "-Ready")
        #expect(plan.check.requireManifest)
    }

    @Test("--timings reaches the capture leg")
    func timingsReachesCapture() throws {
        #expect(try Self.parseRun(["--timings"]).plan(appearances: ["dark"]).capture.timings)
    }

    @Test("run's overrides reach the compose leg")
    func runOverridesReachTheComposeLeg() throws {
        let plan =
            try Self
            .parseRun([
                "--website-out", "/tmp/site",
                "--appearance", "light,dark",
                "--max-width", "1600",
                "--tolerance", "0.5",
            ])
            .plan(appearances: ["dark"])

        #expect(plan.compose.website?.appearance == "light,dark")
        #expect(plan.compose.website?.maxWidth == 1600)
        #expect(plan.check.tolerance == 0.5)
    }

    /// `--website-out` omitted means skip the site leg, not compose it somewhere default.
    @Test("omitting --website-out drops the website leg")
    func websiteLegIsOptional() throws {
        #expect(try Self.parseRun().plan(appearances: []).compose.website == nil)
        #expect(
            try Self.parseRun(["--website-out", "/tmp/site"])
                .plan(appearances: []).compose.website?.out == "/tmp/site")
    }

    /// `run` re-declares knobs its legs own. If the two drift, one of the two `--help`
    /// outputs is lying about what you get.
    @Test("run and the standalone commands agree on defaults")
    func runAndBothAgreeOnDefaults() throws {
        let run = try Self.parseRun()
        let both = try Both.parse([])
        let check = try Check.parse([])

        #expect(run.appearance == both.appearance)
        #expect(run.maxWidth == both.maxWidth)
        #expect(run.tolerance == check.tolerance)
        #expect(run.appstoreOut == both.out)
        #expect(run.requireManifest == check.requireManifest)

        let capture = try CaptureCommand.parse(["--app", "/tmp/X.app", "--screens", "home"])
        #expect(run.settle == capture.settle)
        #expect(run.settleMax == capture.settleMax)
        #expect(run.concurrency.waitTimeout == capture.concurrency.waitTimeout)
        #expect(run.ready.readyArg == capture.ready.readyArg)
    }

    /// Guards the split `Pipeline.website` does on `--appearance`.
    @Test("appearance list tolerates spaces and a trailing comma")
    func appearanceParsing() {
        #expect(Pipeline.appearances(from: "light, dark") == ["light", "dark"])
        #expect(Pipeline.appearances(from: "dark,") == ["dark"])
        #expect(Pipeline.appearances(from: "").isEmpty)
    }
}

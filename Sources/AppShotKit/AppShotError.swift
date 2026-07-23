import Foundation

/// Every failure the library can produce. The CLI turns these into exit codes and
/// messages; the library itself never prints and never exits.
public enum AppShotError: Error, CustomStringConvertible {
    case invalidConfig(URL, String)
    case invalidOutputSize(String, allowed: [String])
    case missingTheme(String)
    case noAppearancesRequested
    case unknownAppearance(String, known: [String])
    case missingCaptures([String], dir: URL)
    case duplicateCaptures([Gate.Duplicate])
    case noCaptures(URL)
    case noGoldens(URL)
    case goldenManifestUnreadable(URL, String)
    case goldenDrift(GoldenManifest.Drift, manifest: GoldenManifest, dir: URL)
    case goldenChangedMidRun([String], dir: URL)
    case goldenUnsealed(URL)
    case fontNotResolved(requested: String, got: String)
    case noRoomForScreenshot(screen: String, textBottom: Int, canvasHeight: Int)
    case imageDecodeFailed(URL)
    case gitLFSPointer(URL)
    case imageEncodeFailed(URL)
    case captureFailed(screen: String, reason: String)
    case appNotFound(URL)
    case appNeverStarted(screen: String)
    case windowNeverAppeared(screen: String)
    case appNeverSignalledReady(screen: String, file: URL, seconds: Double)
    case wouldNotComeToFront(pid: Int32, screen: String)
    case screenRecordingDenied
    case captureLockHeld(CaptureLock.Held, waited: Double?)
    case invalidScreenSpec(String, reason: String)
    case extractFailed(String)
    case missingOutput
    case devicesNeedIOS
    case noDevices
    case invalidDeviceID(String, reason: String)
    case duplicateDeviceID(String)
    case unknownDeviceScreen(device: String, screen: String, known: [String])
    case invalidIgnoreRect(device: String, rect: String, reason: String)
    case unknownDevice(String, known: [String])
    case simctlFailed(command: String, reason: String)
    case simulatorTypeNotFound(String)
    case simulatorRuntimeNotFound(String)
    case notASimulatorBuild(URL, platform: String)
    case bundleIDUnreadable(URL)
    case deviceNeverBooted(String)
    case appNeverAppeared(screen: String, device: String)

    public var description: String {
        switch self {
        case .invalidConfig(let url, let why):
            return "invalid config \(url.path): \(why)"

        case .invalidOutputSize(let size, let allowed):
            return """
                output is \(size), which App Store Connect will reject.
                Use one of: \(allowed.joined(separator: ", "))
                """

        case .missingTheme(let appearance):
            return "no theme for appearance \"\(appearance)\""

        case .noAppearancesRequested:
            return "--appearance is empty — nothing to compose"

        case .unknownAppearance(let requested, let known):
            return """
                unknown appearance "\(requested)" — the config declares: \
                \(known.joined(separator: ", "))
                A typo here would otherwise surface as "capture missing", pointing at the \
                capture run instead of at this flag.
                """

        case .missingCaptures(let names, let dir):
            return """
                \(names.count) capture(s) missing from \(dir.path):
                \(names.map { "   • \($0)" }.joined(separator: "\n"))

                The config expects these; the run did not produce them. Re-capture — a \
                partial set must not travel further down the pipeline.
                """

        case .duplicateCaptures(let duplicates):
            return """
                refusing to accept — \(duplicates.count) set(s) of captures are the same image:
                \(duplicates.map { "   • \($0.reason)" }.joined(separator: "\n"))

                Accepting these would make the duplicate the baseline, and a baseline that \
                disagrees with nothing can never be caught again. Fix the staging and \
                re-capture.
                """

        case .noCaptures(let dir):
            return "no PNGs in \(dir.path) — did capture run?"

        case .noGoldens(let dir):
            return """
                no goldens at \(dir.path).
                Seed them with:  appshot accept
                """

        case .goldenManifestUnreadable(let url, let why):
            return """
                \(url.path) is not a manifest this appshot can read: \(why).
                Re-seal the goldens with `appshot seal` once you are satisfied they are \
                the ones you want.
                """

        case .goldenDrift(let drift, let manifest, let dir):
            // The whole point of the manifest: name the files, and say when and by
            // whom the baseline was last set, so "what wrote to golden" has an answer.
            var out = "the goldens in \(dir.path) changed outside `appshot accept`.\n\n"
            for change in drift.changed {
                out += "   ✗ \(change.name): contents differ from the sealed manifest"
                out += change.modifiedAt.map { " (modified \(stamp($0)))" } ?? ""
                out += "\n"
            }
            for change in drift.unknown {
                out += "   ✗ \(change.name): not in the manifest at all"
                out += change.modifiedAt.map { " (modified \(stamp($0)))" } ?? ""
                out += "\n"
            }
            for name in drift.vanished {
                out += "   ✗ \(name): sealed, but no longer on disk\n"
            }
            if let accept = manifest.accepted {
                out += "\nSealed \(accept.summary)\n"
                out += "   \(accept.argv.joined(separator: " "))\n"
            }
            out += """

                Only `appshot accept` may write here. Restore them \
                (`git checkout -- \(dir.path)`), or — if these *are* the goldens you \
                want — re-seal them deliberately with `appshot seal`.
                A `git lfs pull`, a branch switch or a fresh clone does not cause this: \
                the manifest travels with the goldens, so their contents still agree.
                """
            return out

        case .goldenChangedMidRun(let names, let dir):
            return """
                \(dir.path) changed while this check was running:
                \(names.map { "   • \($0)" }.joined(separator: "\n"))

                Something wrote to the goldens mid-comparison — most likely an \
                `appshot accept` in another terminal. The verdict this run was about to \
                report describes a baseline that no longer exists, so it is being \
                withheld rather than trusted. Re-run it once the other run is done.
                """

        case .goldenUnsealed(let dir):
            return """
                the goldens in \(dir.path) are not sealed, and --require-manifest was \
                passed.
                Nothing can then tell an accepted baseline from one that was edited or \
                overwritten. Seal them once you are satisfied they are right:

                    appshot seal --golden \(dir.path)
                """

        case .fontNotResolved(let requested, let got):
            return """
                the caption font "\(requested)" is not installed — it resolved to "\(got)".
                Store captions would silently ship in the wrong typeface.
                Install it (SF Pro is a free download from developer.apple.com/fonts)
                or change `fontFamily` in the config to one that is present.
                """

        case .noRoomForScreenshot(let screen, let textBottom, let height):
            return """
                \(screen): no room left for the screenshot — the text block ends at \
                \(textBottom)px of a \(height)px canvas.
                Shorten the caption, or reduce layout.textTop / layout.margin.
                """

        case .imageDecodeFailed(let url):
            return "could not decode \(url.lastPathComponent)"

        case .gitLFSPointer(let url):
            return """
                \(url.lastPathComponent) is a Git LFS pointer, not an image — this clone \
                has not fetched the real bytes.

                    git lfs pull

                Everything that only checks the file exists will walk straight past these: \
                they are 131 bytes of text, still named .png.
                """

        case .imageEncodeFailed(let url):
            return "could not write \(url.path)"

        case .captureFailed(let screen, let reason):
            return "\(screen): capture failed — \(reason)"

        case .appNotFound(let url):
            return "no app bundle at \(url.path) (build it first)"

        case .appNeverStarted(let screen):
            return "\(screen): the app never started"

        case .windowNeverAppeared(let screen):
            return "\(screen): the window never appeared"

        case .appNeverSignalledReady(let screen, let file, let seconds):
            return """
                \(screen): the app never signalled ready within \(seconds)s.
                --ready-file passes the app a path to touch once the screen genuinely \
                has its data; nothing was written to
                    \(file.path)

                Either the app does not read the launch argument yet, or that screen \
                really did not finish loading. Falling back to a fixed --settle here \
                would be a guess, which is the thing --ready-file exists to replace — \
                so this stops instead.
                """

        case .wouldNotComeToFront(let pid, let screen):
            return """
                \(screen): pid \(pid) would not come to the front — something else is \
                stealing activation.
                Capturing now would bake an inactive title bar (grey traffic lights, \
                dimmed toolbar) into the image, which looks plausible and is wrong.
                """

        case .screenRecordingDenied:
            return """
                Screen Recording permission is not granted.
                Without it captures fall back to opaque window corners, which the \
                compositor depends on being transparent.
                Grant it in System Settings → Privacy & Security → Screen Recording.
                """

        case .captureLockHeld(let held, let waited):
            // Naming the run is the whole point: a bare pid costs the reader a `ps`
            // to learn the lock belongs to a different project, and there is nothing
            // they can do with the answer that this message cannot do for them.
            var who = "another capture run is in progress"
            if let holder = held.holder {
                who += ": \(holder.summary)"
            } else if let pid = held.pid {
                who += " (pid \(pid))"
            }

            let advice =
                waited.map {
                    """
                    Waited \(CaptureLock.duration($0)) for it to finish. Raise \
                    --wait-timeout, or look at what that run is stuck on.
                    """
                }
                ?? "Wait for it to finish with --wait (bounded by --wait-timeout)."

            return """
                \(who).
                Activation is global — two runs would steal focus from each other and \
                photograph the wrong windows.
                \(advice)
                """

        case .invalidScreenSpec(let spec, let reason):
            return """
                --screens "\(spec)": \(reason).
                Expected name[:stage[:settle]] — e.g. `export`, `export:export-pane`, \
                or `export:export-pane:6` to give that one screen a 6s settle.
                """

        case .extractFailed(let why):
            return "could not extract attachments: \(why)"

        case .missingOutput:
            return """
                the config has no `output` size.
                A Mac config needs one canvas here; an iOS config declares one per entry \
                in `devices[]` instead, and sets `"platform": "ios"`.
                """

        case .devicesNeedIOS:
            return """
                the config has `devices[]` but is not an iOS config.
                Add `"platform": "ios"` — devices are simulators, and the Mac driver has \
                no device to pick.
                """

        case .noDevices:
            return """
                `"platform": "ios"` needs at least one entry in `devices[]`.
                Each one names a simulator and the store canvas its captures compose onto:

                    "devices": [
                      { "id": "iphone", "simulator": "iPhone 17 Pro Max",
                        "output": { "width": 1320, "height": 2868 } }
                    ]
                """

        case .invalidDeviceID(let id, let reason):
            return "device id \"\(id)\" is not usable: \(reason)"

        case .duplicateDeviceID(let id):
            return """
                two devices share the id "\(id)".
                The id is a directory name, so the second device's captures would \
                overwrite the first's.
                """

        case .unknownDeviceScreen(let device, let screen, let known):
            return """
                device "\(device)" lists screen "\(screen)", which is not in screens[].
                Known screens: \(known.joined(separator: ", "))
                """

        case .invalidIgnoreRect(let device, let rect, let reason):
            return """
                device "\(device)" has an unusable ignore rect \(rect): \(reason).
                An ignore rect excludes those pixels from the gate, so one that is wrong \
                weakens the check silently.
                """

        case .unknownDevice(let requested, let known):
            return """
                unknown device "\(requested)" — the config declares: \
                \(known.joined(separator: ", "))
                """

        case .simctlFailed(let command, let reason):
            return """
                simctl \(command) failed: \(reason)
                """

        case .simulatorTypeNotFound(let name):
            return """
                no simulator device type named "\(name)".
                List what is installed with:  xcrun simctl list devicetypes
                """

        case .simulatorRuntimeNotFound(let name):
            return """
                no simulator runtime named "\(name)".
                List what is installed with:  xcrun simctl list runtimes
                """

        case .notASimulatorBuild(let url, let platform):
            return """
                \(url.lastPathComponent) is built for \(platform), not the simulator.
                `simctl install` would reject it with a much less specific error. Build \
                for an iOS Simulator destination:

                    xcodebuild -scheme MyApp -sdk iphonesimulator -derivedDataPath build
                """

        case .bundleIDUnreadable(let url):
            return """
                could not read CFBundleIdentifier from \(url.lastPathComponent)/Info.plist.
                The simulator launches an app by bundle id, so this is how the driver \
                knows what to start.
                """

        case .deviceNeverBooted(let name):
            return """
                the simulator "\(name)" never finished booting.
                `simctl boot` returns long before the device can accept an install — \
                measured at 0.7s against 29s to actually be ready — so this is a real \
                timeout, not a race.
                """

        case .appNeverAppeared(let screen, let device):
            return """
                \(screen): the app never appeared on \(device).
                The screen never stopped looking like it did before launch, so there is \
                nothing to photograph but SpringBoard. Check that the app installed and \
                that its bundle id is what the driver launched.
                """
        }
    }

    /// A stable machine name for the failure.
    ///
    /// `description` is prose and will keep being reworded; something reading
    /// `check --json` needs a key it can branch on that never changes. Spelled out
    /// case by case rather than derived from the case name, so renaming a case in
    /// Swift cannot silently break a caller's `if error.kind == …`.
    public var slug: String {
        switch self {
        case .invalidConfig: return "invalid_config"
        case .invalidOutputSize: return "invalid_output_size"
        case .missingTheme: return "missing_theme"
        case .noAppearancesRequested: return "no_appearances_requested"
        case .unknownAppearance: return "unknown_appearance"
        case .missingCaptures: return "missing_captures"
        case .duplicateCaptures: return "duplicate_captures"
        case .noCaptures: return "no_captures"
        case .noGoldens: return "no_goldens"
        case .goldenManifestUnreadable: return "golden_manifest_unreadable"
        case .goldenDrift: return "golden_drift"
        case .goldenChangedMidRun: return "golden_changed_mid_run"
        case .goldenUnsealed: return "golden_unsealed"
        case .fontNotResolved: return "font_not_resolved"
        case .noRoomForScreenshot: return "no_room_for_screenshot"
        case .imageDecodeFailed: return "image_decode_failed"
        case .gitLFSPointer: return "git_lfs_pointer"
        case .imageEncodeFailed: return "image_encode_failed"
        case .captureFailed: return "capture_failed"
        case .appNotFound: return "app_not_found"
        case .appNeverStarted: return "app_never_started"
        case .windowNeverAppeared: return "window_never_appeared"
        case .appNeverSignalledReady: return "app_never_signalled_ready"
        case .wouldNotComeToFront: return "would_not_come_to_front"
        case .screenRecordingDenied: return "screen_recording_denied"
        case .captureLockHeld: return "capture_lock_held"
        case .invalidScreenSpec: return "invalid_screen_spec"
        case .extractFailed: return "extract_failed"
        case .missingOutput: return "missing_output"
        case .devicesNeedIOS: return "devices_need_ios"
        case .noDevices: return "no_devices"
        case .invalidDeviceID: return "invalid_device_id"
        case .duplicateDeviceID: return "duplicate_device_id"
        case .unknownDeviceScreen: return "unknown_device_screen"
        case .invalidIgnoreRect: return "invalid_ignore_rect"
        case .unknownDevice: return "unknown_device"
        case .simctlFailed: return "simctl_failed"
        case .simulatorTypeNotFound: return "simulator_type_not_found"
        case .simulatorRuntimeNotFound: return "simulator_runtime_not_found"
        case .notASimulatorBuild: return "not_a_simulator_build"
        case .bundleIDUnreadable: return "bundle_id_unreadable"
        case .deviceNeverBooted: return "device_never_booted"
        case .appNeverAppeared: return "app_never_appeared"
        }
    }

    private func stamp(_ date: Date) -> String {
        GoldenManifest.Accept.stamp.string(from: date)
    }
}

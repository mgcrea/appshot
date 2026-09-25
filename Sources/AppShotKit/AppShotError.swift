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
    /// `--max-source-age` was set but the captures carry no run record to age.
    case sourceAgeUnknown(URL)
    /// The captures are older than `--max-source-age` allows.
    case sourceTooOld(dir: URL, age: String, run: String)
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
    /// `--recolor-traffic-lights` found no convincing row of three buttons to repaint.
    case trafficLightsNotFound(screen: String)
    /// The three buttons are neither clearly grey nor clearly coloured.
    case trafficLightsAmbiguous(screen: String, chroma: [Double])
    case screenRecordingDenied
    case captureLockHeld(CaptureLock.Held, waited: Double?)
    case invalidScreenSpec(String, reason: String)
    case extractFailed(String)
    case missingOutput
    case devicesNeedIOS
    case noDevices
    case invalidDeviceID(String, reason: String)
    case duplicateDeviceID(String)
    case invalidDeviceTarget(String, both: Bool)
    case unknownDeviceScreen(device: String, screen: String, known: [String])
    case invalidIgnoreRect(device: String, rect: String, reason: String)
    case invalidBezel(device: String, reason: String)
    case unknownDevice(String, known: [String])
    case noLocales
    case invalidLocaleID(String, reason: String)
    case duplicateLocaleID(String)
    case missingCaption(screen: String, locale: String)
    case unknownScreenLocale(screen: String, locale: String, known: [String])
    case unlocalizedScreen(screen: String, locales: [String])
    case captionsNeedLocales(screen: String)
    case unknownLocale(String, known: [String])
    case simctlFailed(command: String, reason: String)
    case simulatorTypeNotFound(String)
    case simulatorRuntimeNotFound(String)
    case notASimulatorBuild(URL, platform: String)
    case bundleIDUnreadable(URL)
    case deviceNeverBooted(String)
    case appNeverAppeared(screen: String, device: String)
    case hardwareNotFound(String, connected: [String])
    case hardwareUnavailable(String, reason: String)
    case devicectlFailed(command: String, reason: String)
    case notADeviceBuild(URL, platform: String)
    case orientationMismatch(
        screen: String, captured: Config.Size, canvas: Config.Size, frame: URL?)
    case appearanceIgnored(screen: String, appearances: [String])
    case hardwareNeverSignalledReady(screen: String, argument: String, seconds: Double)
    case deviceNotIdle(String, motion: Config.Rect)
    case capturesAreInDeviceDirectories([String], dir: URL)
    case invalidPlate(String)
    case iconSetIncomplete(URL, [Icon.Finding])
    case iconBundleInvalid(URL, [IconComposer.Finding])
    case unknownIconFormat(URL)
    case svgOutputNeedsSVGMark(URL)
    case invalidIconEffect(String, reason: String)
    case iconEffectFailed(String)

    public var description: String {
        switch self {
        case .invalidConfig(let url, let why):
            return "invalid config \(url.path): \(why)"

        case .invalidPlate(let value):
            return "\"\(value)\" is not a #RRGGBB colour"

        case .iconSetIncomplete(let url, let findings):
            return """
                \(url.lastPathComponent) is not a complete macOS icon set:
                \(findings.map { "   • \($0.message)" }.joined(separator: "\n"))

                App Store Connect rejects this at upload, not at build (error 90236 \
                when the 512x512@2x is the one missing).
                """

        case .iconBundleInvalid(let url, let findings):
            return """
                \(url.lastPathComponent) is not a usable Icon Composer bundle:
                \(findings.map { "   • \($0.message)" }.joined(separator: "\n"))

                The system masks a .icon to its own squircle and draws its own shadow, \
                so the base layer is authored square and opaque to all four edges — \
                the opposite of the rounded 824-on-1024 plate an .appiconset carries.
                """

        case .unknownIconFormat(let url):
            return """
                \(url.lastPathComponent) is neither a .appiconset nor a .icon.
                The extension picks the format, because the two want opposite artwork \
                and guessing wrong is silent:

                    --out MyApp/Assets.xcassets/AppIcon.appiconset   rounded 824-on-1024
                    --out MyApp/MyApp.icon                           square full-bleed 1024
                    --out design/icon.svg                            vector, for the web
                """

        case .svgOutputNeedsSVGMark(let url):
            return """
                --out is an .svg but the mark is \(url.lastPathComponent).
                A vector icon needs a vector mark: PDF and bitmap marks work for the \
                formats that rasterise anyway, but embedding one in an SVG produces a \
                file that is vector only in its extension.
                """

        case .invalidIconEffect(let spec, let reason):
            return """
                not a usable icon effect: \(reason)
                    given: \(spec)

                Effects are named fields, comma separated, all optional:

                    angle=270,distance=6,blur=12,opacity=0.22,color=#000000

                angle is degrees counter-clockwise from east with y up, so 270 casts \
                downward and 315 down-right. distance and blur are canvas pixels on a \
                1024 canvas and scale with the output. blur is the Gaussian standard \
                deviation — SVG's stdDeviation — which is about half what a design \
                tool's blur slider shows.
                """

        case .iconEffectFailed(let why):
            return "could not apply the icon effects: \(why)"

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
            // An iOS config nests the goldens one level deeper, under devices[].
            // Without --config a command looks only at the top level, finds nothing,
            // and would otherwise report "no goldens" for a directory that is full of
            // them — pointing at `accept`, which is the one thing that must not be run
            // here: it would overwrite a real baseline with whatever is in source/.
            let nested = Self.deviceSubdirectories(of: dir)
            if !nested.isEmpty {
                return """
                    no goldens directly in \(dir.path), but \(nested.count) \
                    subdirector\(nested.count == 1 ? "y" : "ies") below it \
                    hold PNGs: \(nested.joined(separator: ", ")).
                    That is the iOS layout, where the device is a directory level.
                    Pass the config so the devices can be resolved:
                      --config <screenshots.ios.config.json>
                    Do NOT run `appshot accept` to "fix" this — the goldens are there.
                    """
            }
            return """
                no goldens at \(dir.path).
                Seed them with:  appshot accept
                """

        case .sourceAgeUnknown(let dir):
            return """
                --max-source-age was given, but the captures in \(dir.path) carry no
                run record, so their age is unknown.
                They predate the record, or something other than `appshot capture`
                filled the directory. Re-capture, or drop the flag.
                """

        case .sourceTooOld(let dir, let age, let run):
            return """
                the captures in \(dir.path) are \(age) old — older than
                --max-source-age allows.
                  \(run)
                Almost always this means capture did not run: the build failed, and the
                gate is about to compare last run's images and pass. Re-capture.
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

        case .trafficLightsNotFound(let screen):
            return """
                \(screen): --recolor-traffic-lights found no row of three window buttons \
                in the window's top-left corner, so it left the capture unpainted and stopped.
                Expected three equal discs on one row at an even pitch. A window with a \
                hidden title bar, or something drawn over the buttons, has none to repaint; \
                drop the flag for this app.
                """

        case .trafficLightsAmbiguous(let screen, let chroma):
            let measured = chroma.map { String(format: "%.0f", $0) }.joined(separator: ", ")
            return """
                \(screen): the window buttons are neither grey nor coloured (chroma \
                \(measured)), so --recolor-traffic-lights will not guess at them.
                A pointer hovering over them, or a tinted title bar, can do this.
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

        case .invalidBezel(let device, let reason):
            return """
                device "\(device)" has an unusable bezel: \(reason).
                A bezel is drawn rather than checked against anything, so a broken one \
                renders quietly instead of failing.
                """

        case .unknownDevice(let requested, let known):
            return """
                unknown device "\(requested)" — the config declares: \
                \(known.joined(separator: ", "))
                """

        case .noLocales:
            return """
                `locales[]` is present but empty, so there is no locale to compose into \
                and the run would emit nothing at all.
                Remove the key to go back to a single unlocalized caption per screen, or \
                name the locales:

                    "locales": ["fr-FR", "en-US"]
                """

        case .invalidLocaleID(let id, let reason):
            return "locale \"\(id)\" is not usable: \(reason)"

        case .duplicateLocaleID(let id):
            return """
                `locales[]` names "\(id)" twice.
                The locale is a directory name, so the second pass would overwrite the \
                first's composites.
                """

        case .missingCaption(let screen, let locale):
            return """
                screen "\(screen)" has no caption for locale "\(locale)".
                There is deliberately no fallback to another locale's copy — shipping a \
                listing in the wrong language is worse than not shipping it.
                """

        case .unknownScreenLocale(let screen, let locale, let known):
            return """
                screen "\(screen)" has a caption for "\(locale)", which is not in locales[].
                Declared locales: \(known.joined(separator: ", "))
                """

        case .unlocalizedScreen(let screen, let locales):
            return """
                screen "\(screen)" has a plain `title`, but the config declares \
                locales[]: \(locales.joined(separator: ", ")).
                Move the copy into a `captions` block keyed by locale — a screen carries \
                either one title or one per locale, never both.
                """

        case .captionsNeedLocales(let screen):
            return """
                screen "\(screen)" has a `captions` block but the config declares no \
                locales[], so none of that copy would ever be composed.
                Add the axis:

                    "locales": ["fr-FR", "en-US"]
                """

        case .unknownLocale(let requested, let known):
            if known.isEmpty {
                return """
                    --locale \(requested) was given, but the config declares no locales[] \
                    and composes a single unlocalized set.
                    """
            }
            return """
                unknown locale "\(requested)" — the config declares: \
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

        case .capturesAreInDeviceDirectories(let dirs, let dir):
            return """
                no PNGs directly in \(dir.path) — but \(dirs.count) device \
                director\(dirs.count == 1 ? "y has" : "ies have") them: \
                \(dirs.joined(separator: ", "))

                That is where an iOS run writes, one directory per entry in devices[]. \
                Pass --config so appshot knows about the device axis, or point --source \
                and --golden at one device directly.
                """

        case .appNeverAppeared(let screen, let device):
            return """
                \(screen): the app never appeared on \(device).
                The screen never stopped looking like it did before launch, so there is \
                nothing to photograph but SpringBoard. Check that the app installed and \
                that its bundle id is what the driver launched.
                """

        case .invalidDeviceTarget(let id, let both):
            return both
                ? """
                device "\(id)" names both a "simulator" and a "hardware" device. Pick one: \
                they need different builds (iphonesimulator and iphoneos), and a run can \
                only photograph one screen.
                """
                : """
                device "\(id)" needs a "simulator" (a device type, "iPhone 17 Pro Max") or \
                a "hardware" device (a connected iPhone's name or UDID, as \
                `xcrun devicectl list devices` prints it).
                """

        case .hardwareNotFound(let wanted, let connected):
            let list =
                connected.isEmpty
                ? "No physical iPhone or iPad is paired with this Mac."
                : "Paired: \(connected.joined(separator: ", "))"
            return """
                no paired device named or with UDID "\(wanted)".
                \(list)
                Check with:  xcrun devicectl list devices
                """

        case .hardwareUnavailable(let name, let reason):
            return "\(name) cannot be captured: \(reason)"

        case .devicectlFailed(let command, let reason):
            return """
                devicectl \(command) failed: \(reason)
                A locked device fails here too. Unlock it, and keep it awake for the run \
                (Settings → Display & Brightness → Auto-Lock → Never).
                """

        case .notADeviceBuild(let url, let platform):
            return """
                \(url.lastPathComponent) is built for \(platform), not for a device.
                A "hardware" entry in devices[] installs onto a real iPhone or iPad, which \
                needs a signed iphoneos build:

                    xcodebuild -scheme MyApp -destination 'platform=iOS,id=<udid>' \\
                      -allowProvisioningUpdates -derivedDataPath build

                A config mixing "simulator" and "hardware" devices needs one run per \
                build: `--device <id>` narrows a run to one entry.
                """

        case .orientationMismatch(let screen, let captured, let canvas, let frame):
            return """
                \(screen): the device photographed \(captured.description), but the \
                canvas is \(canvas.description).\(frame.map { " The frame is at\n    \($0.path)" } ?? "")
                A real device captures in whatever orientation it is being held. Turn it \
                to match and lock the rotation (Control Center), or have the app lock its \
                orientation under the demo flag. Nothing is rotated after the fact: a \
                landscape layout rotated onto a portrait canvas is not a portrait screen.
                """

        case .hardwareNeverSignalledReady(let screen, let argument, let seconds):
            return """
                \(screen): the app never signalled ready within \(seconds)s.
                On a real device appshot passes the ready file as
                    \(argument)
                because devicectl never reports where the app's container is. The app has \
                to expand the tilde, which on iOS is its own sandbox, before creating it:

                    FileManager.default.createFile(
                        atPath: (path as NSString).expandingTildeInPath, contents: nil)

                An absolute path from the Mac and simulator drivers passes through that \
                unchanged. If the app already does this, that screen really did not \
                finish loading.
                """

        case .deviceNotIdle(let name, let box):
            return """
                \(name) is not still before the app has even launched: \(box.description) \
                changed between two frames of the idle screen.
                Whatever moves there now will move in every capture. The usual cause is a \
                live activity in the Dynamic Island: music or a podcast playing, a call, a \
                timer, navigation. Stop it, then run again. A notification arriving, or \
                the screen dimming for Auto-Lock, does the same.
                """

        case .appearanceIgnored(let screen, let appearances):
            return """
                \(screen): the \(appearances.joined(separator: " and ")) captures are the \
                same image.
                On a real device appshot cannot set the system appearance, so the app must \
                apply -ScreenshotAppearance itself under the demo flag — for SwiftUI, \
                `.preferredColorScheme` on the root view, or `overrideUserInterfaceStyle` \
                on its windows. Until it does, every "dark" golden is a light one.
                """
        }
    }

    /// Immediate subdirectories of `dir` that contain at least one PNG, sorted.
    ///
    /// Only ever called on an error path, to tell "this directory is empty" apart from
    /// "this directory is an iOS golden tree and you forgot --config". Scanning here
    /// rather than at the throw site keeps both callers (`Gate`, `GateSelfTest`) from
    /// having to know about the distinction.
    static func deviceSubdirectories(of dir: URL) -> [String] {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )
        else { return [] }
        return
            entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { sub in
                let inner = (try? fm.contentsOfDirectory(atPath: sub.path)) ?? []
                return inner.contains { $0.lowercased().hasSuffix(".png") }
            }
            .map(\.lastPathComponent)
            .sorted()
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
        case .invalidPlate: return "invalid_plate"
        case .iconSetIncomplete: return "icon_set_incomplete"
        case .iconBundleInvalid: return "icon_bundle_invalid"
        case .unknownIconFormat: return "unknown_icon_format"
        case .svgOutputNeedsSVGMark: return "svg_output_needs_svg_mark"
        case .invalidIconEffect: return "invalid_icon_effect"
        case .iconEffectFailed: return "icon_effect_failed"
        case .invalidOutputSize: return "invalid_output_size"
        case .missingTheme: return "missing_theme"
        case .noAppearancesRequested: return "no_appearances_requested"
        case .unknownAppearance: return "unknown_appearance"
        case .missingCaptures: return "missing_captures"
        case .duplicateCaptures: return "duplicate_captures"
        case .noCaptures: return "no_captures"
        case .noGoldens: return "no_goldens"
        case .sourceAgeUnknown: return "source_age_unknown"
        case .sourceTooOld: return "source_too_old"
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
        case .trafficLightsNotFound: return "traffic_lights_not_found"
        case .trafficLightsAmbiguous: return "traffic_lights_ambiguous"
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
        case .invalidBezel: return "invalid_bezel"
        case .unknownDevice: return "unknown_device"
        case .noLocales: return "no_locales"
        case .invalidLocaleID: return "invalid_locale_id"
        case .duplicateLocaleID: return "duplicate_locale_id"
        case .missingCaption: return "missing_caption"
        case .unknownScreenLocale: return "unknown_screen_locale"
        case .unlocalizedScreen: return "unlocalized_screen"
        case .captionsNeedLocales: return "captions_need_locales"
        case .unknownLocale: return "unknown_locale"
        case .simctlFailed: return "simctl_failed"
        case .simulatorTypeNotFound: return "simulator_type_not_found"
        case .simulatorRuntimeNotFound: return "simulator_runtime_not_found"
        case .notASimulatorBuild: return "not_a_simulator_build"
        case .bundleIDUnreadable: return "bundle_id_unreadable"
        case .deviceNeverBooted: return "device_never_booted"
        case .appNeverAppeared: return "app_never_appeared"
        case .invalidDeviceTarget: return "invalid_device_target"
        case .hardwareNotFound: return "hardware_not_found"
        case .hardwareUnavailable: return "hardware_unavailable"
        case .devicectlFailed: return "devicectl_failed"
        case .notADeviceBuild: return "not_a_device_build"
        case .orientationMismatch: return "orientation_mismatch"
        case .appearanceIgnored: return "appearance_ignored"
        case .hardwareNeverSignalledReady: return "hardware_never_signalled_ready"
        case .deviceNotIdle: return "device_not_idle"
        case .capturesAreInDeviceDirectories: return "captures_in_device_directories"
        }
    }

    private func stamp(_ date: Date) -> String {
        GoldenManifest.Accept.stamp.string(from: date)
    }
}

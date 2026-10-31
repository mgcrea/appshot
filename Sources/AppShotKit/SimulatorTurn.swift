import Foundation

/// Turns an appshot simulator to its canvas's orientation.
///
/// A simulator boots in portrait and nothing outside a UI test can turn it: `simctl` has
/// no orientation command, Xcode 27 ships no Simulator.app to press Rotate in, and iPadOS
/// refuses a resizable app's own `requestGeometryUpdate`. `XCUIDevice.shared.orientation`
/// can, but only from a UI-testing bundle. Measured: the same call in a Swift package's
/// test target fails with "Not authorized for performing UI testing actions", after ten
/// minutes. So appshot carries the smallest such bundle there is, as text: an Xcode
/// project with one UI-test target and no app to test, built once per Xcode and kept in
/// `~/Library/Caches/appshot`. A turn is then one `test-without-building` of one test
/// method, ~4s; the first build costs ~5s more.
///
/// The turn lasts until the simulator reboots, and every project on a Mac shares
/// `appshot-<id>`: a landscape run turns its device back to portrait on the way out.
public enum SimulatorTurn {

    public enum Orientation: String, Sendable, Equatable {
        case portrait
        case landscape

        /// The way up a canvas, and so its captures, has to be. A square counts as
        /// portrait, which is how a simulator boots.
        public init(_ size: Config.Size) {
            self = size.width > size.height ? .landscape : .portrait
        }

        /// The test method that turns the device this way.
        var test: String {
            switch self {
            case .portrait: return "testPortrait"
            case .landscape: return "testLandscape"
            }
        }
    }

    // MARK: - Commands

    /// The xcodebuild invocations, as values, for the same reason as `Simulator.Command`:
    /// each is otherwise a booted device away from being checked.
    public enum Command: Sendable, Equatable {
        case version
        case build(project: String, derivedData: String)
        case turn(xctestrun: String, udid: String, to: Orientation)

        public var argv: [String] {
            switch self {
            case .version:
                return ["xcodebuild", "-version"]
            case .build(let project, let derivedData):
                // Generic, so one build serves every simulator and runtime.
                return [
                    "xcodebuild", "build-for-testing", "-quiet",
                    "-project", project, "-scheme", runnerTarget,
                    "-destination", "generic/platform=iOS Simulator",
                    "-derivedDataPath", derivedData,
                ]
            case .turn(let xctestrun, let udid, let orientation):
                // The allowance is the ceiling on a turn that cannot happen. Without it,
                // XCTest waits ten minutes before reporting a refused UI-testing action.
                return [
                    "xcodebuild", "test-without-building", "-quiet",
                    "-xctestrun", xctestrun,
                    "-destination", "id=\(udid)",
                    "-only-testing:\(runnerTarget)/\(runnerClass)/\(orientation.test)",
                    "-test-timeouts-enabled", "YES",
                    "-default-test-execution-time-allowance", "60",
                    "-maximum-test-execution-time-allowance", "60",
                ]
            }
        }
    }

    // MARK: - Turning

    /// Turn the device and wait for the turn to be reported done. The test asserts the
    /// orientation took, so a zero exit is a turned device.
    public static func turn(_ device: Simulator.Device, to orientation: Orientation) throws {
        let xctestrun: URL
        do {
            xctestrun = try runner()
        } catch let error as AppShotError {
            throw error
        } catch {
            throw AppShotError.simulatorTurnFailed(
                device: device.name, orientation: orientation.rawValue, reason: "\(error)")
        }
        let result = try xcrun(.turn(xctestrun: xctestrun.path, udid: device.udid, to: orientation))
        guard result.status == 0 else {
            throw AppShotError.simulatorTurnFailed(
                device: device.name, orientation: orientation.rawValue,
                reason: summary(result.output, status: result.status))
        }
    }

    // MARK: - The runner

    /// Bumped whenever the project or test text below changes, so a cached build of the
    /// old text is never run.
    static let runnerVersion = 1
    static let runnerTarget = "AppShotTurner"
    static let runnerClass = "TurnTests"

    /// Per Xcode build: a test bundle built by one Xcode is not one another can run.
    static func cacheDirectory(xcodeBuild: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "appshot/turner-v\(runnerVersion)/\(xcodeBuild)")
    }

    /// The runner's `.xctestrun`, building it first if this Xcode never has.
    ///
    /// Built in a scratch directory and moved into place, so two devices captured at once
    /// never run a half-written bundle. The `.xctestrun` names its bundle relative to its
    /// own directory, so the move does not break it.
    static func runner() throws -> URL {
        let directory = cacheDirectory(xcodeBuild: try xcodeBuild())
        if let built = xctestrun(in: directory) { return built }

        let fm = FileManager.default
        let scratch = directory.deletingLastPathComponent()
            .appending(path: ".building-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: scratch) }
        try write(project: scratch)
        let result = try xcrun(
            .build(
                project: scratch.appending(path: "\(runnerTarget).xcodeproj").path,
                derivedData: scratch.appending(path: "build").path))
        guard result.status == 0 else {
            throw AppShotError.turnRunnerBuildFailed(
                summary(result.output, status: result.status))
        }
        // Another run may have finished first; its build is as good as this one.
        try? fm.moveItem(at: scratch, to: directory)
        guard let built = xctestrun(in: directory) else {
            throw AppShotError.turnRunnerBuildFailed("no .xctestrun under \(directory.path)")
        }
        return built
    }

    static func xctestrun(in directory: URL) -> URL? {
        let products = directory.appending(path: "build/Build/Products")
        return
            (try? FileManager.default.contentsOfDirectory(
                at: products, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "xctestrun" }
    }

    /// "Build version 27A5218c", the last line of `xcodebuild -version`.
    static func xcodeBuild() throws -> String {
        let result = try xcrun(.version)
        guard result.status == 0,
            let line = result.output.split(separator: "\n").last(where: {
                $0.hasPrefix("Build version ")
            })
        else {
            throw AppShotError.turnRunnerBuildFailed(
                "`xcodebuild -version` did not name a build: "
                    + summary(result.output, status: result.status))
        }
        return String(line.dropFirst("Build version ".count))
            .trimmingCharacters(in: .whitespaces)
    }

    static func write(project directory: URL) throws {
        let fm = FileManager.default
        let sources = directory.appending(path: runnerTarget)
        let schemes = directory.appending(
            path: "\(runnerTarget).xcodeproj/xcshareddata/xcschemes")
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)
        try fm.createDirectory(at: schemes, withIntermediateDirectories: true)
        try testSource.write(
            to: sources.appending(path: "\(runnerClass).swift"), atomically: true,
            encoding: .utf8)
        try projectFile.write(
            to: directory.appending(path: "\(runnerTarget).xcodeproj/project.pbxproj"),
            atomically: true, encoding: .utf8)
        try schemeFile.write(
            to: schemes.appending(path: "\(runnerTarget).xcscheme"), atomically: true,
            encoding: .utf8)
    }

    /// The last lines of xcodebuild's output, which is where it says what went wrong.
    static func summary(_ output: String, status: Int32) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.contains("[MT]") }
        guard !lines.isEmpty else { return "exit \(status)" }
        return lines.suffix(8).joined(separator: "\n")
    }

    // MARK: - Running xcodebuild

    struct Output {
        let status: Int32
        /// stdout and stderr together, in the order xcodebuild wrote them.
        let output: String
    }

    static func xcrun(_ command: Command) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = command.argv
        // One pipe for both: read in turn, two pipes deadlock when the unread one fills.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw AppShotError.turnRunnerBuildFailed("could not run xcodebuild: \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(
            status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    // MARK: - The runner's text

    static let testSource = """
        import XCTest

        // Written by appshot, which turns its simulators with this. See SimulatorTurn.
        final class \(runnerClass): XCTestCase {
            @MainActor func testLandscape() { turn(to: .landscapeLeft) }
            @MainActor func testPortrait() { turn(to: .portrait) }

            @MainActor private func turn(to orientation: UIDeviceOrientation) {
                XCUIDevice.shared.orientation = orientation
                XCTAssertEqual(XCUIDevice.shared.orientation, orientation)
            }
        }

        """

    /// No app to test: `XCUIDevice` needs only the UI-testing runner, and an ad-hoc
    /// signature is all a simulator asks of it.
    static let projectFile = """
        // !$*UTF8*$!
        {
        	archiveVersion = 1;
        	classes = {
        	};
        	objectVersion = 77;
        	objects = {
        		A00000000000000000000001 /* Project object */ = {
        			isa = PBXProject;
        			buildConfigurationList = A00000000000000000000002;
        			mainGroup = A00000000000000000000003;
        			minimizedProjectReferenceProxies = 1;
        			preferredProjectObjectVersion = 77;
        			productRefGroup = A00000000000000000000004;
        			projectDirPath = "";
        			projectRoot = "";
        			targets = (
        				A00000000000000000000010,
        			);
        		};
        		A00000000000000000000002 = {
        			isa = XCConfigurationList;
        			buildConfigurations = (
        				A00000000000000000000005,
        			);
        			defaultConfigurationName = Debug;
        		};
        		A00000000000000000000005 = {
        			isa = XCBuildConfiguration;
        			buildSettings = {
        				ALWAYS_SEARCH_USER_PATHS = NO;
        				SDKROOT = iphoneos;
        			};
        			name = Debug;
        		};
        		A00000000000000000000003 = {
        			isa = PBXGroup;
        			children = (
        				A00000000000000000000006,
        				A00000000000000000000004,
        			);
        			sourceTree = "<group>";
        		};
        		A00000000000000000000004 /* Products */ = {
        			isa = PBXGroup;
        			children = (
        				A00000000000000000000007,
        			);
        			name = Products;
        			sourceTree = "<group>";
        		};
        		A00000000000000000000006 = {
        			isa = PBXFileSystemSynchronizedRootGroup;
        			path = \(runnerTarget);
        			sourceTree = "<group>";
        		};
        		A00000000000000000000007 = {
        			isa = PBXFileReference;
        			explicitFileType = wrapper.cfbundle;
        			includeInIndex = 0;
        			path = \(runnerTarget).xctest;
        			sourceTree = BUILT_PRODUCTS_DIR;
        		};
        		A00000000000000000000010 = {
        			isa = PBXNativeTarget;
        			buildConfigurationList = A00000000000000000000011;
        			buildPhases = (
        				A00000000000000000000012,
        			);
        			buildRules = (
        			);
        			dependencies = (
        			);
        			fileSystemSynchronizedGroups = (
        				A00000000000000000000006,
        			);
        			name = \(runnerTarget);
        			productName = \(runnerTarget);
        			productReference = A00000000000000000000007;
        			productType = "com.apple.product-type.bundle.ui-testing";
        		};
        		A00000000000000000000012 = {
        			isa = PBXSourcesBuildPhase;
        			buildActionMask = 2147483647;
        			files = (
        			);
        			runOnlyForDeploymentPostprocessing = 0;
        		};
        		A00000000000000000000011 = {
        			isa = XCConfigurationList;
        			buildConfigurations = (
        				A00000000000000000000013,
        			);
        			defaultConfigurationName = Debug;
        		};
        		A00000000000000000000013 = {
        			isa = XCBuildConfiguration;
        			buildSettings = {
        				CODE_SIGN_IDENTITY = "-";
        				CODE_SIGN_STYLE = Manual;
        				GENERATE_INFOPLIST_FILE = YES;
        				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
        				PRODUCT_BUNDLE_IDENTIFIER = io.mgcrea.appshot.\(runnerTarget);
        				PRODUCT_NAME = "$(TARGET_NAME)";
        				SDKROOT = iphoneos;
        				SUPPORTED_PLATFORMS = iphonesimulator;
        				SWIFT_VERSION = 5.0;
        				TARGETED_DEVICE_FAMILY = "1,2";
        			};
        			name = Debug;
        		};
        	};
        	rootObject = A00000000000000000000001;
        }

        """

    static let schemeFile = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme version = "1.7">
           <TestAction buildConfiguration = "Debug">
              <Testables>
                 <TestableReference skipped = "NO">
                    <BuildableReference
                       BuildableIdentifier = "primary"
                       BlueprintIdentifier = "A00000000000000000000010"
                       BuildableName = "\(runnerTarget).xctest"
                       BlueprintName = "\(runnerTarget)"
                       ReferencedContainer = "container:\(runnerTarget).xcodeproj">
                    </BuildableReference>
                 </TestableReference>
              </Testables>
           </TestAction>
        </Scheme>

        """
}

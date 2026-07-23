//
//  ScreenshotHarness.swift
//
//  Drop-in helpers for an XCUITest screenshot pipeline. Copy into your UI test
//  target and adjust `appBundleID`. Every helper exists because of a specific
//  failure — the comment above each one names it, so you know what you're
//  giving up if you delete it.
//
//  macOS uses ScreenCaptureKit so window corners keep their true alpha. On iOS,
//  ignore the capture section and use `XCUIScreen.main.screenshot()`; the
//  attachment helper applies to both.
//

import XCTest
#if os(macOS)
import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
#endif

// MARK: - Attachments (both platforms)

extension XCTestCase {
    /// Attach a PNG to the test result so it survives the runner's sandbox.
    ///
    /// The UI-test runner cannot write into your repo. `.keepAlways` keeps the
    /// attachment even when the test passes (the default discards it), so
    /// `appshot extract --xcresult` exports it, restoring this name as the filename.
    func attachPNG(_ data: Data, named name: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name          // becomes the exported filename
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

#if os(macOS)

// MARK: - macOS screenshot harness

/// Subclass this, or copy the members you need.
class ScreenshotTestCase: XCTestCase {

    /// Set to your app's bundle identifier.
    var appBundleID: String { "com.example.MyApp" }

    /// Transparent capture background. A stored property because
    /// `SCStreamConfiguration.backgroundColor` is `unowned(unsafe)` — passing a
    /// temporary CGColor dangles.
    private let clearColor = CGColor(gray: 0, alpha: 0)

    /// PID of the app *this test* launched.
    ///
    /// A developer's real copy of the app is usually already running under the
    /// same bundle id. Selecting windows by bundle id would photograph their
    /// real window, with their real data. Always scope to this PID.
    var testAppPID: pid_t?

    // MARK: Launch

    func runningPIDs() -> Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == appBundleID }
            .map(\.processIdentifier))
    }

    /// Poll for a process that did not exist before `launch()`. Launch is not
    /// instantaneous, so a single check races.
    func resolveTestAppPID(excluding existing: Set<pid_t>, timeout: TimeInterval = 10) -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = runningPIDs().subtracting(existing).first { return pid }
            usleep(200_000)
        }
        return nil
    }

    /// Launch in demo mode and take ownership of the resulting process.
    ///
    /// On macOS, `app.activate()` here is a *hint*, not the mechanism — the test
    /// process cannot reliably raise the app. The app must activate **itself**
    /// (`NSApplication.shared.activate(ignoringOtherApps: true)` from its root
    /// view's `.task`, behind the demo flag). Without that the app stays behind
    /// the runner, its window never becomes key, every accessibility query spins
    /// until it times out, and `typeKey` — which delivers to whatever app is
    /// frontmost — goes nowhere at all, so the run captures nothing while still
    /// reporting success. See references/macos.md.
    @discardableResult
    @MainActor
    func launchDemoApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppDemoMode", "YES",
            // Suppresses window open/close animation, cutting capture noise.
            "-NSAutomaticWindowAnimationsEnabled", "NO",
            // Never restore saved window state. After any crash mid-run, macOS
            // blocks the *next* launch with a modal "reopen its windows?" alert:
            // the main window never appears and the capture degrades to a
            // full-screen shot of the developer's desktop.
            "-ApplePersistenceIgnoreState", "YES",
        ] + extraArguments

        let preexisting = runningPIDs()
        app.launch()
        app.activate()
        testAppPID = resolveTestAppPID(excluding: preexisting)
        XCTAssertNotNil(testAppPID, "Could not identify the launched app process")
        return app
    }

    // MARK: Quiescence

    /// Let animations and async rendering finish. Use *after* waiting on real
    /// content — this is for the last few frames, not a substitute for
    /// `waitForExistence`.
    func settle(_ seconds: TimeInterval = 0.7) {
        usleep(useconds_t(seconds * 1_000_000))
    }

    /// Park the pointer somewhere inert.
    ///
    /// The cursor keeps whatever position the last interaction left it in. If
    /// that lands on a row with a hover highlight or a `.help` tooltip, it is
    /// baked into the capture. Verify the chosen corner is inert in *your*
    /// layout.
    @MainActor
    func parkCursor(_ window: XCUIElement) {
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.99)).hover()
    }

    /// Return the first candidate that exists within `timeout`.
    ///
    /// Useful where the accessibility element type isn't knowable ahead of time
    /// — SwiftUI's `List` maps to an outline or a table depending on style, and
    /// macOS Settings tabs are sometimes buttons, sometimes radio buttons.
    @MainActor
    func firstExisting(_ candidates: [XCUIElement], timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for candidate in candidates where candidate.exists { return candidate }
            usleep(300_000)
        }
        return nil
    }

    /// Click, then verify the click actually landed.
    ///
    /// The first click on a window that has just become key is frequently
    /// swallowed while it takes focus. Retrying blindly is not enough — retry
    /// until the *consequence* is observable.
    @MainActor
    @discardableResult
    func click(_ element: XCUIElement, until expected: XCUIElement,
               attempts: Int = 3, timeout: TimeInterval = 5) -> Bool {
        for _ in 0..<attempts {
            element.click()
            if expected.waitForExistence(timeout: timeout) { return true }
        }
        return false
    }

    // MARK: Capture

    /// Capture `element`'s window (plus any sheet in front of it) and attach it.
    ///
    /// Prefers ScreenCaptureKit so the window's rounded corners keep their true
    /// alpha; `XCUIScreenshot` would bake in the desktop pixels behind them.
    /// Falls back when Screen Recording isn't granted — loudly, and fatally
    /// under STRICT_CAPTURE=1, because silently shipping opaque corners is worse
    /// than a red build.
    @MainActor
    func capture(_ element: XCUIElement, named name: String) async {
        if let image = await captureWindowImage(matching: element),
           let data = pngData(from: image) {
            attachPNG(data, named: "\(name).png")
            return
        }

        let strict = ProcessInfo.processInfo.environment["STRICT_CAPTURE"] == "1"
        let message = """
        ScreenCaptureKit capture failed for \(name). \
        Grant Screen Recording to the UI-test runner for transparent corners.
        """
        if strict {
            XCTFail(message)
            return
        }
        print("⚠️  \(message) Falling back to XCUIScreenshot.")

        let target = element.exists ? element : XCUIApplication()
        attachPNG(target.screenshot().pngRepresentation, named: "\(name).png")
    }

    /// The launched app's on-screen windows, front-to-back, as (id, bounds).
    ///
    /// `CGWindowListCopyWindowInfo` is not deprecated — only the image-producing
    /// `CGWindowListCreateImage` variants are. We use it purely for z-order and
    /// window ids, strictly scoped to `testAppPID` (see the property's comment).
    private func appWindows() -> [(id: CGWindowID, bounds: CGRect)] {
        guard let pid = testAppPID,
              let infos = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        return infos.compactMap { info in
            guard let num = info[kCGWindowNumber as String] as? CGWindowID,
                  info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  let dict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary)
            else { return nil }
            return (num, bounds)
        }
    }

    @MainActor
    private func captureWindowImage(matching element: XCUIElement) async -> CGImage? {
        guard element.exists, CGPreflightScreenCaptureAccess() else { return nil }
        let target = element.frame
        let windows = appWindows()
        guard !windows.isEmpty else { return nil }

        // The base window is the one overlapping `element` most — not simply the
        // frontmost, which may be a sheet or another app's panel.
        func overlap(_ r: CGRect) -> CGFloat {
            let i = r.intersection(target)
            return i.isNull ? 0 : i.width * i.height
        }
        guard let baseIndex = windows.indices.max(by: { overlap(windows[$0].bounds) < overlap(windows[$1].bounds) }),
              overlap(windows[baseIndex].bounds) > 0
        else { return nil }
        let base = windows[baseIndex]

        // Include the base and everything layered in *front* of it that overlaps
        // (a sheet must appear). Exclude what's behind, or the base window's
        // transparent corners fill with the window underneath.
        let ids = Set(windows[...baseIndex]
            .filter { !$0.bounds.intersection(base.bounds).isNull }
            .map(\.id))

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let scWindows = content.windows.filter { ids.contains($0.windowID) }
            guard !scWindows.isEmpty,
                  let display = content.displays.first(where: { $0.frame.intersects(base.bounds) })
                    ?? content.displays.first
            else { return nil }

            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let config = SCStreamConfiguration()
            config.showsCursor = false
            config.backgroundColor = clearColor
            // sourceRect is display-relative; window bounds are global.
            config.sourceRect = base.bounds.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            config.width = Int((base.bounds.width * scale).rounded())
            config.height = Int((base.bounds.height * scale).rounded())

            let filter = SCContentFilter(display: display, including: scWindows)
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            print("⚠️  ScreenCaptureKit error: \(error)")
            return nil
        }
    }

    private func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

#endif

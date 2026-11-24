import Foundation

/// Compiles symbol assets with `actool`, the only judge of whether Xcode will take them, into
/// a bundle `NSImage(symbolName:bundle:variableValue:)` can load from.
public enum SymbolCatalog {
    /// `actool` comes with Xcode only; the Command Line Tools alone have no `actool`.
    public static func actool() throws -> URL {
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "actool"]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw AppShotError.symbolNoActool
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !path.isEmpty,
            FileManager.default.isExecutableFile(atPath: path)
        else { throw AppShotError.symbolNoActool }
        return URL(fileURLWithPath: path)
    }

    /// Compiles `catalog`, an `.xcassets` or a folder of `.symbolset`s (wrapped in a scratch
    /// `.xcassets` first), into a scratch `.bundle`, left in the temporary directory for the
    /// caller to load from.
    ///
    /// - Returns: the bundle and `actool`'s warnings.
    /// - Throws: `AppShotError.symbolCatalogRejected` with `actool`'s errors.
    public static func compile(_ catalog: URL) throws -> (bundle: Bundle, warnings: [String]) {
        let tool = try actool()
        let fm = FileManager.default
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-symbols-\(UUID().uuidString)")
        let bundleURL = scratch.appending(path: "Symbols.bundle")
        let resources = bundleURL.appending(path: "Contents/Resources")
        let assets = scratch.appending(path: "Wrapper.xcassets")
        // Only the bundle outlives the call, and only when it compiled.
        var compiled = false
        defer { try? fm.removeItem(at: compiled ? assets : scratch) }
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        // A plain folder is copied in as a group, as it sits inside the app's own catalog.
        var input = catalog
        var wrapper: URL?
        if catalog.pathExtension != "xcassets" {
            try fm.createDirectory(at: assets, withIntermediateDirectories: true)
            try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8)
                .write(to: assets.appending(path: "Contents.json"))
            try fm.copyItem(at: catalog, to: assets.appending(path: catalog.lastPathComponent))
            input = assets
            wrapper = assets
        }

        // To files rather than pipes: a catalog with many bad symbols writes more than a
        // pipe holds, and actool would block on it.
        let outURL = scratch.appending(path: "actool.out")
        let errURL = scratch.appending(path: "actool.err")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)
        let process = Process()
        process.executableURL = tool
        process.arguments = [
            "--compile", resources.path,
            "--platform", "macosx",
            "--minimum-deployment-target", "14.0",
            "--output-format", "human-readable-text",
            "--warnings", "--errors",
            input.path,
        ]
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw AppShotError.symbolCatalogRejected("actool did not start: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        try? out.close()
        try? err.close()

        let report = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        try? fm.removeItem(at: outURL)
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        try? fm.removeItem(at: errURL)

        // Messages name the scratch copy; name the caller's folder instead.
        func unscratched(_ line: String) -> String {
            guard let wrapper else { return line }
            var line = line
            for root in [wrapper.path, wrapper.resolvingSymlinksInPath().path] {
                for form in [root, root.replacingOccurrences(of: "/private/", with: "/")] {
                    // "<catalog>:./<item>", file paths and file:// URLs, then the wrapper.
                    let folder = catalog.lastPathComponent
                    line = line.replacingOccurrences(
                        of: "\(form):./\(folder)/", with: "\(catalog.path):./")
                    line = line.replacingOccurrences(of: "\(form)/\(folder)", with: catalog.path)
                    line = line.replacingOccurrences(of: form, with: catalog.path)
                }
            }
            return line
        }
        let sections = Self.sections(report)
        let errors = sections.filter { $0.key.hasSuffix("errors") }.sorted { $0.key < $1.key }
            .flatMap(\.value).map(unscratched)
        let warnings = sections.filter { $0.key.hasSuffix("warnings") }.sorted { $0.key < $1.key }
            .flatMap(\.value).map(unscratched)

        guard process.terminationStatus == 0, errors.isEmpty else {
            let why =
                errors.isEmpty
                ? stderr.trimmingCharacters(in: .whitespacesAndNewlines) : errors.joined(separator: "\n")
            throw AppShotError.symbolCatalogRejected(
                why.isEmpty ? "actool exited with status \(process.terminationStatus)" : unscratched(why))
        }

        let plist: [String: Any] = [
            "CFBundleIdentifier": "io.appshot.symbols.\(scratch.lastPathComponent)",
            "CFBundleName": "Symbols",
            "CFBundlePackageType": "BNDL",
            "CFBundleInfoDictionaryVersion": "6.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundleURL.appending(path: "Contents/Info.plist"))
        guard let bundle = Bundle(url: bundleURL) else {
            throw AppShotError.symbolCatalogRejected("the compiled bundle at \(bundleURL.path) does not load")
        }
        compiled = true
        return (bundle, warnings)
    }

    /// actool's human-readable report: a `/* com.apple.actool.errors */` line opens each
    /// section, and the lines up to the next one are its entries.
    static func sections(_ report: String) -> [String: [String]] {
        var sections: [String: [String]] = [:]
        var current: String?
        for line in report.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("/* "), text.hasSuffix(" */") {
                let name = String(text.dropFirst(3).dropLast(3))
                sections[name, default: []] += []
                current = name
            } else if let current, !text.isEmpty {
                sections[current, default: []].append(text)
            }
        }
        return sections
    }
}

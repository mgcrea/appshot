import Foundation

/// Export screenshot attachments from an `.xcresult` bundle.
///
/// Only needed by projects whose captures come from an XCUITest (Silhouette) rather
/// than the staged shell driver. The test runner is sandboxed out of the repo, so
/// each capture travels as an `XCTAttachment` whose *name* is the final filename.
public enum Extractor {
    /// Extract every PNG attachment, then verify the exact expected set arrived.
    ///
    /// A count check is not enough: a run can produce the right number of files with
    /// two duplicated and two missing. And a test that executes zero tests still
    /// exits `TEST SUCCEEDED`, so without the set check a run that captured nothing
    /// copies the previous run's images out and reports them as fresh.
    @discardableResult
    public static func run(
        xcresult: URL,
        outDir: URL,
        expected: [String]? = nil
    ) throws -> [String] {
        try Compose.wipePNGs(in: outDir)

        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "appshot-xcresult-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xcresulttool", "export", "attachments",
            "--path", xcresult.path,
            "--output-path", staging.path,
        ]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw AppShotError.extractFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // The manifest maps the exported (UUID) filenames back to the attachment
        // names the test chose, which are the filenames we actually want.
        let manifestURL = staging.appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw AppShotError.extractFailed("no manifest.json in the exported attachments")
        }

        struct Entry: Decodable {
            struct Attachment: Decodable {
                let suggestedHumanReadableName: String?
                let exportedFileName: String
            }
            let attachments: [Attachment]?
        }
        let entries = try JSONDecoder().decode([Entry].self, from: data)

        var extracted: [String] = []
        for entry in entries {
            for attachment in entry.attachments ?? [] {
                guard
                    let name = attachment.suggestedHumanReadableName,
                    name.lowercased().hasSuffix(".png")
                else { continue }
                // XCTest also auto-attaches a screenshot whenever a test fails. Those
                // are debugging aids, not store assets.
                guard !name.contains("Failure") else { continue }

                let from = staging.appending(path: attachment.exportedFileName)
                let to = outDir.appending(path: name)
                try? FileManager.default.removeItem(at: to)
                try FileManager.default.copyItem(at: from, to: to)
                extracted.append(name)
            }
        }

        if let expected {
            let missing = Set(expected).subtracting(extracted).sorted()
            guard missing.isEmpty else {
                throw AppShotError.missingCaptures(missing, dir: outDir)
            }
        } else if extracted.isEmpty {
            throw AppShotError.extractFailed("no PNG attachments in \(xcresult.lastPathComponent)")
        }

        return extracted
    }
}

import Foundation
import Testing
@testable import AppShotKit

/// The goldens live in Git LFS. A clone that has not run `git lfs pull` gets 131-byte
/// text pointers *still named .png* — and every "does the file exist" check walks
/// straight past them.
struct LFSTests {
    static let pointer = """
        version https://git-lfs.github.com/spec/v1
        oid sha256:a61a02d85c73ab0c1fd7ebcd00d590e8aab5277fed9ae0c8e373cf8ca4061f4a
        size 421729

        """

    /// The one that matters. Two pointers for the same object are byte-identical, so
    /// the gate's sha256 fast path would short-circuit and report a clean match —
    /// passing every screenshot without ever decoding one.
    @Test func pointersDoNotSneakThroughTheHashFastPath() throws {
        let (root, cand, gold) = try GateTests.tempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        for dir in [cand, gold] {
            try Self.pointer.write(
                to: dir.appending(path: "a.png"), atomically: true, encoding: .utf8)
        }

        #expect(throws: AppShotError.self) {
            try Gate.compare(candidateDir: cand, goldenDir: gold)
        }
    }

    @Test func recognisesAPointerAndNotARealPNG() throws {
        let (root, cand, _) = try GateTests.tempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        let pointer = cand.appending(path: "pointer.png")
        try Self.pointer.write(to: pointer, atomically: true, encoding: .utf8)
        #expect(Image.isGitLFSPointer(pointer))

        let real = cand.appending(path: "real.png")
        try Image.write(GateTests.makeImage(), to: real)
        #expect(!Image.isGitLFSPointer(real))
    }
}

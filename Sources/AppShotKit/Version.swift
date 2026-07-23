/// The one place the version is written down.
///
/// Keep in step with the git tag — the release workflow refuses to publish a binary
/// whose `--version` disagrees with the tag it was built from. It lives here rather
/// than in the CLI's `CommandConfiguration` because the capture lock and the golden
/// manifest both stamp it into files that outlive the run: a golden accepted by an
/// unknown version is a golden nobody can reason about later.
public enum AppShotVersion {
    public static let current = "0.5.0"
}

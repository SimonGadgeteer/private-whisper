import Foundation

/// The running build's identity, for Settings, the About panel and the log.
/// `PWGitCommit` is stamped into the bundle's Info.plist by scripts/build_app.sh.
enum AppVersion {
    private static let info = Bundle.main.infoDictionary ?? [:]

    static var version: String { info["CFBundleShortVersionString"] as? String ?? "dev" }
    static var build: String { info["CFBundleVersion"] as? String ?? "?" }
    static var commit: String? { info["PWGitCommit"] as? String }

    /// "build 5, commit 87f0f59"
    static var details: String {
        commit.map { "build \(build), commit \($0)" } ?? "build \(build)"
    }

    /// "0.2.5 (build 5, commit 87f0f59)"
    static var full: String { "\(version) (\(details))" }
}

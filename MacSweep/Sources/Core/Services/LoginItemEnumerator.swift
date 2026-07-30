import Foundation

typealias LoginItemCommandRunner = @Sendable (
    _ executable: String,
    _ arguments: [String],
    _ timeout: TimeInterval
) async throws -> ProcessResult

/// Read-only enumeration of macOS login items, launch agents, and launch
/// daemons for the headless/CLI surface.
///
/// This is a Core-module port of the read paths in `LoginItemsService`
/// (which lives in the GUI-only Features module and so is unreachable from
/// CLIKit). It intentionally omits all mutation (enable/disable/delete) and
/// AI analysis — the CLI surfaces enumeration only.
actor LoginItemEnumerator {
    private let isRoot: @Sendable () -> Bool
    private let commandRunner: LoginItemCommandRunner
    private let userLaunchAgents = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents")
    private let systemLaunchAgents = URL(fileURLWithPath: "/Library/LaunchAgents")
    private let systemLaunchDaemons = URL(fileURLWithPath: "/Library/LaunchDaemons")

    init(
        isRoot: @escaping @Sendable () -> Bool = { geteuid() == 0 },
        commandRunner: @escaping LoginItemCommandRunner = { executable, arguments, timeout in
            try await ProcessRunner.run(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        }
    ) {
        self.isRoot = isRoot
        self.commandRunner = commandRunner
    }

    func enumerate() async -> [HeadlessLoginItem] {
        var collected: [HeadlessLoginItem] = []
        collected += await appServiceItems()
        collected += launchItems(at: userLaunchAgents, kind: .launchAgent)
        collected += launchItems(at: systemLaunchAgents, kind: .launchAgent)
        collected += launchItems(at: systemLaunchDaemons, kind: .launchDaemon)
        return collected
    }

    // MARK: - SMAppService (sfltool dumpbtm)

    /// Kept internal so focused tests can exercise the subprocess boundary
    /// without enumerating the host's real launch-agent directories.
    func appServiceItems() async -> [HeadlessLoginItem] {
        // `sfltool dumpbtm` requires root on macOS 13+. Run without privileges
        // it produces no output and never exits — it would hang the caller.
        // Skip it unless we're root; launch agents/daemons below still
        // enumerate fine for unprivileged callers.
        guard isRoot() else { return [] }

        // ProcessRunner concurrently drains stdout/stderr and bounds the entire
        // lifecycle, including descendants retaining a pipe descriptor. Keep
        // this read best-effort: a failed or timed-out root-only probe must not
        // prevent launch-agent/daemon enumeration.
        guard let result = try? await commandRunner(
            "/usr/bin/sfltool",
            ["dumpbtm"],
            10
        ), result.didSucceed else {
            return []
        }

        return parseSfltoolOutput(result.output)
    }

    /// `internal` (not `private`) so the pure `sfltool dumpbtm` text parser can be
    /// exercised directly from `@testable import` unit tests without spawning the
    /// root-only subprocess. Touches no actor state, so callers reach it via `await`.
    func parseSfltoolOutput(_ output: String) -> [HeadlessLoginItem] {
        var result: [HeadlessLoginItem] = []
        var currentName: String?
        var currentPath: String?
        var currentBundleID: String?

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name = ") {
                currentName = trimmed
                    .replacingOccurrences(of: "name = ", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if trimmed.hasPrefix("url = ") || trimmed.hasPrefix("executableURL = ") {
                let raw = trimmed
                    .replacingOccurrences(of: "url = ", with: "")
                    .replacingOccurrences(of: "executableURL = ", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                // Decode the file:// URL via URL(string:) so percent-encoded
                // components (e.g. "My%20App.app") become a real POSIX path;
                // dropFirst(7) would leave them encoded and break path lookups.
                if raw.hasPrefix("file://"), let fileURL = URL(string: raw) {
                    currentPath = fileURL.path
                } else {
                    currentPath = raw
                }
            } else if trimmed.hasPrefix("bundleIdentifier = ") {
                currentBundleID = trimmed
                    .replacingOccurrences(of: "bundleIdentifier = ", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if trimmed == "}" || trimmed == "}," {
                if let name = currentName, let path = currentPath {
                    result.append(HeadlessLoginItem(
                        name: name,
                        path: path,
                        kind: .appService,
                        bundleIdentifier: currentBundleID,
                        enabled: true,
                        plistPath: nil
                    ))
                }
                currentName = nil
                currentPath = nil
                currentBundleID = nil
            }
        }
        return result
    }

    // MARK: - Launch Agents / Daemons

    private func launchItems(at directory: URL, kind: HeadlessLoginItemKind) -> [HeadlessLoginItem] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "plist" }
            .compactMap { parsePlist(at: $0, kind: kind) }
    }

    private func parsePlist(at url: URL, kind: HeadlessLoginItemKind) -> HeadlessLoginItem? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }

        let label = plist["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
        let args = plist["ProgramArguments"] as? [String] ?? []
        let program = plist["Program"] as? String ?? args.first ?? url.path
        let disabled = plist["Disabled"] as? Bool ?? false

        return HeadlessLoginItem(
            name: label,
            path: program,
            kind: kind,
            bundleIdentifier: nil,
            enabled: !disabled,
            plistPath: url.path
        )
    }
}

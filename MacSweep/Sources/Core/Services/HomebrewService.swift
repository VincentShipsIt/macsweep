import Foundation

typealias HomebrewCommandRunner = @Sendable (
    _ executable: String,
    _ arguments: [String],
    _ timeout: TimeInterval
) async throws -> ProcessResult

typealias HomebrewStreamingCommandRunner = @Sendable (
    _ executable: String,
    _ arguments: [String],
    _ timeout: TimeInterval,
    _ onOutput: @escaping ProcessOutputHandler
) async throws -> ProcessResult

@MainActor
class HomebrewService: ObservableObject {
    static let commandTimeout: TimeInterval = 300

    @Published var packages: [BrewPackage] = []
    @Published var isLoading = false
    @Published var isUpgrading = false
    @Published var upgradeLog = ""
    /// Real exit status of the last `brew upgrade` run by `runUpgrade(args:)`
    /// (true == exit 0). Read by the headless bridge so `homebrew upgrade` can
    /// report failure instead of always claiming success. nil until a run completes.
    @Published var lastUpgradeSucceeded: Bool?
    @Published var error: String?
    @Published var isAnalyzingAI = false

    private let commandRunner: HomebrewCommandRunner
    private let streamingCommandRunner: HomebrewStreamingCommandRunner

    init(
        streamingCommandRunner: @escaping HomebrewStreamingCommandRunner = { executable, arguments, timeout, onOutput in
            try await ProcessRunner.runStreaming(
                executable: executable,
                arguments: arguments,
                timeout: timeout,
                onOutput: onOutput
            )
        },
        commandRunner: @escaping HomebrewCommandRunner = { executable, arguments, timeout in
            try await ProcessRunner.run(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        }
    ) {
        self.streamingCommandRunner = streamingCommandRunner
        self.commandRunner = commandRunner
    }

    // MARK: - Public API

    func checkOutdated() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        guard brewExists() else {
            error = "brew_not_found"
            return
        }

        let output = await runBrew(brewPath(), ["outdated", "--json=v2"]).output
        guard let data = output.data(using: .utf8) else {
            error = "Failed to parse brew output"
            return
        }

        do {
            let response = try JSONDecoder().decode(BrewOutdatedResponse.self, from: data)
            var result: [BrewPackage] = []

            for formula in response.formulae {
                let installed = formula.installedVersions.first ?? "unknown"
                result.append(BrewPackage(
                    id: UUID(),
                    name: formula.name,
                    currentVersion: installed,
                    latestVersion: formula.currentVersion,
                    isOutdated: true,
                    isSelected: true
                ))
            }

            for cask in response.casks {
                let installed = cask.installedVersions.first ?? "unknown"
                result.append(BrewPackage(
                    id: UUID(),
                    name: "\(cask.name) (cask)",
                    currentVersion: installed,
                    latestVersion: cask.currentVersion,
                    isOutdated: true,
                    isSelected: true
                ))
            }

            packages = result
        } catch {
            self.error = "Failed to parse brew output: \(error.localizedDescription)"
        }
    }

    func upgradeSelected() async {
        let selected = packages.filter(\.isSelected).map { $0.name.replacingOccurrences(of: " (cask)", with: "") }
        guard !selected.isEmpty else { return }
        await runUpgrade(packageNames: selected)
    }

    func upgradeAll() async {
        await runUpgrade(packageNames: [])
    }

    func analyzeWithAI() async {
        guard !packages.isEmpty else { return }
        guard let apiKey = AIKeychainService.shared.loadKey(), !apiKey.isEmpty else {
            error = "No Anthropic API key configured. Add it in Settings."
            return
        }

        isAnalyzingAI = true
        defer { isAnalyzingAI = false }

        // Resolve REAL dependency edges among the outdated set so the model orders
        // upgrades from actual `brew deps`, not a guess. Casks have no `brew deps`
        // graph, so the cask suffix is stripped before querying.
        let cleanNames = packages.map { $0.name.replacingOccurrences(of: " (cask)", with: "") }
        let outdatedSet = Set(cleanNames)
        var depsByName: [String: [String]] = [:]
        for name in cleanNames {
            // Run brew directly with array args — a formula name is never spliced
            // into a shell string, so a malicious/unusual name can't inject.
            let raw = await runBrew(brewPath(), ["deps", name]).output
            let deps = raw.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // Only edges WITHIN the outdated set matter for ordering this batch.
            depsByName[name] = deps.filter { outdatedSet.contains($0) }
        }

        let packageList: [[String: Any]] = packages.map { pkg in
            let clean = pkg.name.replacingOccurrences(of: " (cask)", with: "")
            return [
                "name": pkg.name,
                "from": pkg.currentVersion,
                "to": pkg.latestVersion,
                "dependsOn": depsByName[clean] ?? []
            ]
        }
        guard let packagesJSON = try? JSONSerialization.data(withJSONObject: packageList),
              let packagesString = String(data: packagesJSON, encoding: .utf8) else { return }

        let prompt = """
You are a macOS Homebrew expert. For each outdated package, analyze the version jump and provide:
- A 1-sentence summary of what changed
- Whether there are breaking changes (true/false)
- If breaking: what specifically breaks
- Upgrade recommendation: "Safe" or "Review first"
- Upgrade order (1=upgrade first). Derive the order STRICTLY from the `dependsOn` field:
  a package must be upgraded AFTER every package listed in its `dependsOn`. Packages
  with an empty `dependsOn` can go first. Do NOT guess dependencies — use only `dependsOn`.

Packages: \(packagesString)
Return JSON array in same order: [{"changesSummary":"...","hasBreakingChanges":false,"breakingChangesDetail":null,"upgradeRecommendation":"Safe","upgradeOrder":1}]
Only return the JSON array, no other text.
"""

        do {
            let insights = try await callClaude(prompt: prompt, apiKey: apiKey)
            for (index, insight) in insights.enumerated() {
                if index < packages.count {
                    packages[index].aiInsight = insight
                }
            }
        } catch {
            self.error = "AI analysis failed: \(error.localizedDescription)"
        }
    }

    /// Reclaim disk by removing stale downloads and old installed versions
    /// (`brew cleanup -s`). Returns the full log plus the reclaimed-space line Brew
    /// prints, when present. Read-mostly: brew only deletes its own cached artifacts.
    func cleanup() async -> (success: Bool, reclaimedText: String?, log: String) {
        guard brewExists() else { return (false, nil, "brew_not_found") }
        let result = await runBrew(brewPath(), ["cleanup", "-s"])
        // Brew emits e.g. "==> This operation has freed approximately 1.2GB of disk space."
        let reclaimed = result.output
            .components(separatedBy: .newlines)
            .first { $0.lowercased().contains("freed approximately") }?
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "==> ", with: "")
        // Success reflects brew's real exit status, not merely that brew exists.
        return (result.didSucceed, reclaimed, Self.commandLog(result))
    }

    /// Top-level formulae — installed packages that are NOT a dependency of any other
    /// installed formula (`brew leaves`). These are the packages the user explicitly
    /// wanted; everything else is a pulled-in dependency.
    func leaves() async -> [String] {
        guard brewExists() else { return [] }
        let output = await runBrew(brewPath(), ["leaves"]).output
        return output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Homebrew command that upgrades MacSweep itself via its tap. Printed by the
    /// CLI's `self-update` (no `--yes`) so the user can run it manually, and executed
    /// directly by `selfUpgrade()`.
    static let selfUpgradeCommand = "brew upgrade vincentshipsit/tap/macsweep"

    /// Upgrade the installed `macsweep` formula in place. Caller is responsible for
    /// checking `brewExists()` first; this guards too and returns a sentinel log so
    /// the headless layer can map the absence to the right exit code.
    func selfUpgrade() async -> (success: Bool, log: String) {
        guard brewExists() else { return (false, "brew_not_found") }
        let result = await runBrew(brewPath(), ["upgrade", "vincentshipsit/tap/macsweep"])
        // Success reflects brew's real exit status — a failed upgrade must not
        // report applied:true to the headless/CLI layer.
        return (result.didSucceed, Self.commandLog(result))
    }

    // MARK: - Private

    private func runUpgrade(packageNames: [String]) async {
        isUpgrading = true
        upgradeLog = ""
        lastUpgradeSucceeded = nil
        defer { isUpgrading = false }

        // Pass each package name as a separate argument to the brew binary — no
        // shell, so names can never inject. Empty list = upgrade everything.
        let arguments = ["upgrade"] + packageNames
        let executable = brewPath()
        upgradeLog = "Running: \(([executable] + arguments).joined(separator: " "))\n\n"

        let (outputStream, outputContinuation) = AsyncStream.makeStream(of: String.self)
        let outputConsumer = Task { @MainActor [weak self] in
            for await chunk in outputStream {
                self?.upgradeLog += chunk
            }
        }

        let decoder = StreamingUTF8Decoder()
        let onOutput: ProcessOutputHandler = { stream, data in
            let chunk = decoder.decode(data, from: stream)
            guard !chunk.isEmpty else { return }
            outputContinuation.yield(chunk)
        }

        let completionMessage: String
        do {
            let result = try await streamingCommandRunner(
                executable,
                arguments,
                Self.commandTimeout,
                onOutput
            )
            lastUpgradeSucceeded = result.didSucceed
            completionMessage = result.didSucceed
                ? "\n✅ Done (exit code: \(result.status))"
                : "\n❌ Error (exit code: \(result.status))"
        } catch ProcessRunnerError.timedOut(let timeout, _) {
            lastUpgradeSucceeded = false
            completionMessage = "\n❌ Error: Homebrew upgrade timed out after \(timeout) seconds"
        } catch ProcessRunnerError.launchFailed(let reason) {
            lastUpgradeSucceeded = false
            completionMessage = "\n❌ Error: failed to launch brew: \(reason)"
        } catch {
            lastUpgradeSucceeded = false
            completionMessage = "\n❌ Error: \(error.localizedDescription)"
        }

        for chunk in decoder.finish() {
            outputContinuation.yield(chunk)
        }
        outputContinuation.finish()
        await outputConsumer.value
        upgradeLog += completionMessage

        // Refresh package list
        await checkOutdated()
    }

    private func callClaude(prompt: String, apiKey: String) async throws -> [BrewUpdateInsight] {
        let text = try await AnthropicMessagesClient.complete(
            prompt: prompt,
            apiKey: apiKey,
            model: .sonnet,
            maxTokens: 4096
        )
        let jsonText = AnthropicMessagesClient.extractJSONArray(from: text)
        guard let jsonData = jsonText.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode([BrewUpdateInsight].self, from: jsonData)
    }

    func brewExists() -> Bool {
        HomebrewPaths.isInstalled
    }

    private func brewPath() -> String {
        // Falls back to the Intel prefix when brew isn't installed, preserving the
        // prior behaviour (callers gate on brewExists() first).
        HomebrewPaths.brewPath ?? "/usr/local/bin/brew"
    }

}

extension HomebrewService {
    /// Run a non-streaming brew command through the shared argv-only runner.
    ///
    /// The live `runUpgrade(packageNames:)` path stays separate because it
    /// incrementally appends output to the visible upgrade log. This method is
    /// internal so tests can verify the command boundary without invoking brew.
    func runBrew(
        _ brewPath: String,
        _ arguments: [String],
        timeout: TimeInterval = HomebrewService.commandTimeout
    ) async -> ProcessResult {
        do {
            return try await commandRunner(brewPath, arguments, timeout)
        } catch ProcessRunnerError.timedOut(_, let partialResult) {
            let timeoutMessage = "Homebrew command timed out after \(timeout) seconds"
            let diagnostic = partialResult.error.trimmingCharacters(in: .whitespacesAndNewlines)
            return ProcessResult(
                status: 124,
                output: partialResult.output,
                error: diagnostic.isEmpty ? timeoutMessage : "\(diagnostic)\n\(timeoutMessage)",
                outputWasValidUTF8: partialResult.outputWasValidUTF8
            )
        } catch {
            return ProcessResult(
                status: 1,
                output: "",
                error: String(describing: error)
            )
        }
    }

    /// Parsing callers consume stdout only; user-facing command logs retain
    /// Homebrew's progress and diagnostics from stderr without corrupting JSON.
    static func commandLog(_ result: ProcessResult) -> String {
        guard !result.output.isEmpty else { return result.error }
        guard !result.error.isEmpty else { return result.output }
        let separator = result.output.hasSuffix("\n") || result.error.hasPrefix("\n") ? "" : "\n"
        return result.output + separator + result.error
    }
}

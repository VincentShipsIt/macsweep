import Foundation

typealias CacheAnalyzerExecutableResolver = @Sendable (_ command: String) -> String?
typealias CacheAnalyzerCommandRunner = @Sendable (
    _ executable: String,
    _ arguments: [String],
    _ timeout: TimeInterval
) async throws -> ProcessResult

/// Deterministic + optional AI-assisted developer-cache scanner.
///
/// Ported from the GUI-only `AIAnalysisService` into Core so the headless/CLI
/// layer can drive the same logic. The fast scan is pure deterministic shell
/// discovery and always runs; the AI scan prefers local assistant CLIs
/// (`claude -p`, then `codex exec`) and falls back to an Anthropic key stored in
/// the Keychain only when no local provider succeeds. No state is mutated and
/// nothing is deleted — this is read-only reconnaissance.
struct CacheAnalyzer {
    private static let fastScanTimeout: TimeInterval = 300
    private static let providerTimeout: TimeInterval = 600

    private enum ProviderAttempt {
        case success(findings: [Finding], provider: String)
        case failure(String)
    }

    private let executableResolver: CacheAnalyzerExecutableResolver
    private let commandRunner: CacheAnalyzerCommandRunner

    init(
        executableResolver: @escaping CacheAnalyzerExecutableResolver = {
            CacheAnalyzer.executablePath(for: $0)
        },
        commandRunner: @escaping CacheAnalyzerCommandRunner = { executable, arguments, timeout in
            try await ProcessRunner.run(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        }
    ) {
        self.executableResolver = executableResolver
        self.commandRunner = commandRunner
    }

    /// Mirrors the GUI `CacheCategory` raw values so JSON output is identical
    /// across the app and CLI.
    enum Category: String {
        case electronChromium = "Electron/Chromium"
        case packageManager = "Package Manager"
        case devDebugLogs = "Dev Debug Logs"
        case aiToolCache = "AI Tool Cache"
        case other = "Other"
    }

    struct Finding {
        let path: String
        /// Exact on-disk size when the finding comes from the deterministic fast
        /// scan; `nil` for AI findings, whose sizes are free-text estimates.
        let sizeBytes: Int64?
        let sizeText: String
        let category: Category
        let regeneratesAutomatically: Bool
        let source: String   // "Fast Scan" | "AI Analysis"
        let reason: String?
    }

    struct Result {
        let findings: [Finding]
        let fastCount: Int
        let aiRan: Bool
        let errors: [String]
    }

    /// Run the deterministic fast scan (always) plus, when `deep` is true, an AI
    /// semantic scan using local CLIs before falling back to the stored API key.
    /// AI results are deduplicated against fast-scan paths. Errors are collected
    /// rather than thrown so a failed AI call still returns deterministic findings.
    func analyze(deep: Bool) async -> Result {
        var errors: [String] = []
        let fast = await runFastScan()
        var findings = fast
        var aiRan = false

        if deep {
            let dirList = await largestApplicationSupportDirectories()
            let prompt = makeAIPrompt(dirList: dirList)
            let local = await runLocalAIScan(prompt: prompt)

            if local.provider != nil {
                let existing = Set(findings.map { $0.path })
                findings.append(contentsOf: local.findings.filter { !existing.contains($0.path) })
                aiRan = true
                if let error = local.error { errors.append(error) }
            } else if let key = AIKeychainService.shared.loadKey() {
                let anthropic = await runAnthropicScan(apiKey: key, prompt: prompt)
                let existing = Set(findings.map { $0.path })
                findings.append(contentsOf: anthropic.findings.filter { !existing.contains($0.path) })
                aiRan = true
                if let error = anthropic.error { errors.append(error) }
            } else {
                if let error = local.error {
                    errors.append(error)
                }
                errors.append("AI scan requested but no Claude/Codex CLI or Anthropic API key is available.")
            }
        }

        return Result(findings: findings, fastCount: fast.count, aiRan: aiRan, errors: errors)
    }

    // MARK: - Fast Scan

    /// Cache directories that regenerate automatically — safe to surface for
    /// cleanup. Matched by `find -path`; the `*` globs are find's own, passed
    /// through literally in the argv (no shell to expand them).
    private static let fastScanPathPatterns = [
        "*/Library/Application Support/*/Code Cache",
        "*/Library/Application Support/*/GPUCache",
        "*/Library/Application Support/*/DawnWebGPUCache",
        "*/Library/Application Support/*/DawnGraphiteCache",
        "*/Library/Application Support/*/ShaderCache",
        "*/vm_bundles/warm",
        "*/.npm/_cacache",
        "*/.npm/_npx",
        "*/.npm/_logs",
        "*/.bun/install/cache",
        "*/.yarn/cache",
        "*/.pnpm-store",
        "*/.cache/pip",
        "*/.cache/uv",
        "*/.cargo/registry",
        "*/.cargo/git",
        "*/go/pkg/mod",
        "*/.cache/go-build",
        "*/.gradle/caches",
        "*/.m2/repository",
        "*/.claude/debug",
        "*/.claude/paste-cache",
        "*/.claude/telemetry",
        "*/.claude/shell-snapshots",
        "*/.codex/log",
        "*/.codex/archived_sessions"
    ]

    private func runFastScan() async -> [Finding] {
        // Replaces `find ~ … -print0 | xargs -0 du -sk | sort -rn` with an
        // argv-only pipeline. `~` is expanded here since there is no shell.
        // `du -sk` (raw KiB, not -sh's human strings) feeds the exact byte
        // counts the DTO layer serializes as `sizeBytes` (#99).
        var findArguments = [NSHomeDirectory(), "-maxdepth", "8", "("]
        for (index, pattern) in Self.fastScanPathPatterns.enumerated() {
            if index > 0 { findArguments.append("-o") }
            findArguments.append(contentsOf: ["-path", pattern])
        }
        findArguments.append(contentsOf: [")", "-type", "d", "-prune", "-print0"])

        return await Task.detached(priority: .userInitiated) {
            let output = await Self.bestEffortPipelineOutput(
                stages: [
                    ProcessPipelineStage(
                        executable: "/usr/bin/find",
                        arguments: findArguments
                    ),
                    ProcessPipelineStage(
                        executable: "/usr/bin/xargs",
                        arguments: ["-0", "/usr/bin/du", "-sk"]
                    ),
                    ProcessPipelineStage(
                        executable: "/usr/bin/sort",
                        arguments: ["-rn"]
                    )
                ],
                timeout: Self.fastScanTimeout
            )
            return Self.parseFastScanOutput(output)
        }.value
    }

    /// Pure transform of `du -sk` tab-separated output (KiB + path) into findings.
    /// `internal` (not `private`) so the deterministic parse/categorize logic is
    /// reachable from `@testable import` unit tests.
    static func parseFastScanOutput(_ output: String) -> [Finding] {
        output.components(separatedBy: "\n").compactMap { line -> Finding? in
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 2 else { return nil }
            let size = parts[0].trimmingCharacters(in: .whitespaces)
            let path = parts[1].trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, let kibibytes = Int64(size) else { return nil }
            let bytes = kibibytes * 1024
            return Finding(
                path: path,
                sizeBytes: bytes,
                sizeText: bytes.formattedFileSize,
                category: categorize(path: path),
                regeneratesAutomatically: true,
                source: "Fast Scan",
                reason: nil
            )
        }
    }

    static func categorize(path: String) -> Category {
        let p = path.lowercased()
        if p.contains("code cache") || p.contains("gpucache") || p.contains("dawn") ||
           p.contains("shadercache") || p.contains("vm_bundles/warm") {
            return .electronChromium
        }
        if p.contains(".npm") || p.contains(".bun") || p.contains(".yarn") ||
           p.contains(".pnpm") || p.contains(".cache/pip") || p.contains(".cache/uv") ||
           p.contains(".cargo") || p.contains("/go/pkg/mod") || p.contains("go-build") ||
           p.contains(".gradle/caches") || p.contains(".m2/repository") {
            return .packageManager
        }
        if p.contains(".claude") || p.contains(".codex") {
            return .aiToolCache
        }
        if p.contains("debug") || p.contains("/log") || p.contains("archived_sessions") {
            return .devDebugLogs
        }
        return .other
    }

    // MARK: - AI Scan

    private func largestApplicationSupportDirectories() async -> String {
        await Task.detached(priority: .userInitiated) {
            // Replaces `du -sh ~/Library/Application\ Support/*/ | sort -rh | head -50`.
            // The shell glob `*/` is expanded here to immediate, non-hidden
            // subdirectories so no path is ever passed through a shell.
            let appSupport = NSHomeDirectory() + "/Library/Application Support"
            let fileManager = FileManager.default
            let directories = ((try? fileManager.contentsOfDirectory(atPath: appSupport)) ?? [])
                .filter { !$0.hasPrefix(".") }
                .map { appSupport + "/" + $0 }
                .filter { path in
                    var isDirectory: ObjCBool = false
                    return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                }
                .sorted()
                .map { $0 + "/" }   // trailing slash matches the `*/` the shell produced
            guard !directories.isEmpty else { return "" }

            let output = await Self.bestEffortPipelineOutput(
                stages: [
                    ProcessPipelineStage(
                        executable: "/usr/bin/du",
                        arguments: ["-sh"] + directories
                    ),
                    ProcessPipelineStage(
                        executable: "/usr/bin/sort",
                        arguments: ["-rh"]
                    )
                ],
                timeout: Self.fastScanTimeout
            )
            // `head -50`
            return output
                .split(separator: "\n", omittingEmptySubsequences: false)
                .prefix(50)
                .joined(separator: "\n")
        }.value
    }

    private static func bestEffortPipelineOutput(
        stages: [ProcessPipelineStage],
        timeout: TimeInterval
    ) async -> String {
        do {
            return try await ProcessRunner.runPipeline(
                stages: stages,
                timeout: timeout
            ).output
        } catch let error as ProcessPipelineStageError {
            return error.partialResult.output
        } catch ProcessRunnerError.timedOut(after: _, partialResult: let partialResult) {
            return partialResult.output
        } catch {
            return ""
        }
    }

    private func makeAIPrompt(dirList: String) -> String {
        """
        You are a disk cleanup scanner for macOS developer machines.

        Here are the largest directories in ~/Library/Application Support:
        \(dirList)

        Identify safe-to-delete cache directories. Categories:
        1. Electron/Chromium: "Code Cache", "GPUCache", "DawnWebGPUCache", "DawnGraphiteCache", "ShaderCache", "warm" in "vm_bundles/"
        2. Package Manager: .npm/_cacache, .npm/_npx, .bun/install/cache, .yarn/cache, .pnpm-store, .cache/pip, .cache/uv
        3. Dev Debug Logs: dotdir's "debug", "log", "logs", "archived_sessions"
        4. AI Tool Caches: .claude/debug, .claude/paste-cache, .claude/telemetry, .claude/shell-snapshots

        NEVER flag: /projects/, /sessions/, /global/, *.json, *.bundle, vm_bundles/claudevm.bundle, ~/.bun/install/global

        Respond ONLY with a JSON array (no markdown):
        [{"path":"...","size_estimate":"...","category":"Electron/Chromium|Package Manager|Dev Debug Logs|AI Tool Cache|Other","regenerates_automatically":true,"reason":"..."}]
        """
    }

    func runLocalAIScan(prompt: String) async -> (findings: [Finding], provider: String?, error: String?) {
        var errors: [String] = []

        if let attempt = await runClaude(prompt: prompt) {
            switch attempt {
            case .success(let findings, let provider):
                return (findings, provider, nil)
            case .failure(let error):
                errors.append(error)
            }
        }

        if let attempt = await runCodex(prompt: prompt) {
            switch attempt {
            case .success(let findings, let provider):
                return (findings, provider, nil)
            case .failure(let error):
                errors.append(error)
            }
        }

        return ([], nil, errors.isEmpty ? nil : errors.joined(separator: " "))
    }

    private func runClaude(prompt: String) async -> ProviderAttempt? {
        guard let executable = executableResolver("claude") else { return nil }

        let invocation = await runProvider(
            "Claude CLI",
            executable: executable,
            arguments: [
                "-p",
                "--json-schema", Self.aiSchemaString,
                prompt
            ]
        )
        if let error = invocation.error {
            return .failure(error)
        }
        guard let result = invocation.result else {
            return .failure("Claude CLI scan failed")
        }
        guard result.didSucceed else {
            return .failure(Self.processError("Claude CLI", result))
        }
        guard let findings = Self.parseAIFindings(result.output, source: "AI Analysis") else {
            return .failure("Claude CLI returned an unparseable AI scan response.")
        }
        return .success(findings: findings, provider: "Claude CLI")
    }

    private func runCodex(prompt: String) async -> ProviderAttempt? {
        guard let executable = executableResolver("codex") else { return nil }

        let temporaryDirectory = FileManager.default.temporaryDirectory
        let schemaURL = temporaryDirectory.appending(
            path: "macsweep-cache-schema-\(UUID().uuidString).json"
        )
        let outputURL = temporaryDirectory.appending(
            path: "macsweep-cache-\(UUID().uuidString).json"
        )
        defer {
            try? FileManager.default.removeItem(at: schemaURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        do {
            try Self.aiSchemaString.write(to: schemaURL, atomically: true, encoding: .utf8)
        } catch {
            return .failure("Codex CLI scan failed: \(error.localizedDescription)")
        }

        let invocation = await runProvider(
            "Codex CLI",
            executable: executable,
            arguments: [
                "exec",
                "--skip-git-repo-check",
                "--sandbox", "read-only",
                "--ephemeral",
                "--output-schema", schemaURL.path,
                "-o", outputURL.path,
                prompt
            ]
        )
        if let error = invocation.error {
            return .failure(error)
        }
        guard let result = invocation.result else {
            return .failure("Codex CLI scan failed")
        }
        guard result.didSucceed else {
            return .failure(Self.processError("Codex CLI", result))
        }
        let text = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? result.output
        guard let findings = Self.parseAIFindings(text, source: "AI Analysis") else {
            return .failure("Codex CLI returned an unparseable AI scan response.")
        }
        return .success(findings: findings, provider: "Codex CLI")
    }

    /// POST the largest `~/Library/Application Support` directories to the
    /// Anthropic Messages API and parse the JSON array of suggested cache dirs.
    /// Returns `(findings, error?)` — errors are surfaced, never thrown.
    private func runAnthropicScan(apiKey: String, prompt: String) async -> (findings: [Finding], error: String?) {
        do {
            let text = try await AnthropicMessagesClient.complete(
                prompt: prompt,
                apiKey: apiKey,
                model: .haiku,
                maxTokens: 2048
            )
            guard let findings = Self.parseAIFindings(text, source: "AI Analysis") else {
                return ([], "AI scan returned an unparseable response.")
            }
            return (findings, nil)
        } catch {
            return ([], "AI scan failed: \(error.localizedDescription)")
        }
    }

    private static func parseAIFindings(_ text: String, source: String) -> [Finding]? {
        let cleaned = AnthropicMessagesClient.extractJSONArray(from: text)
        guard let arrayData = cleaned.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: arrayData) as? [[String: Any]] else {
            return nil
        }

        return items.compactMap { item -> Finding? in
            guard let path = item["path"] as? String else { return nil }
            let size = item["size_estimate"] as? String ?? "Unknown"
            let cat = item["category"] as? String ?? "Other"
            let regen = item["regenerates_automatically"] as? Bool ?? true
            let reason = item["reason"] as? String
            return Finding(
                path: path,
                sizeBytes: nil,
                sizeText: size,
                category: Category(rawValue: cat) ?? .other,
                regeneratesAutomatically: regen,
                source: source,
                reason: reason
            )
        }
    }

    // MARK: - Shell helper

    private static func executablePath(for command: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(command).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func runProvider(
        _ provider: String,
        executable: String,
        arguments: [String]
    ) async -> (result: ProcessResult?, error: String?) {
        do {
            return (
                try await commandRunner(executable, arguments, Self.providerTimeout),
                nil
            )
        } catch ProcessRunnerError.timedOut(let timeout, let partialResult) {
            return (
                nil,
                Self.processError(
                    provider,
                    partialResult,
                    context: "timed out after \(Int(timeout))s"
                )
            )
        } catch {
            return (nil, "\(provider) scan failed: \(String(describing: error))")
        }
    }

    private static func processError(
        _ provider: String,
        _ result: ProcessResult,
        context: String = "failed"
    ) -> String {
        let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            : result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = "\(provider) scan \(context)"
        return message.isEmpty ? summary : "\(summary): \(message)"
    }

    private static var aiSchemaString: String {
        """
        {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["path", "size_estimate", "category", "regenerates_automatically"],
            "properties": {
              "path": { "type": "string" },
              "size_estimate": { "type": "string" },
              "category": {
                "type": "string",
                "enum": ["Electron/Chromium", "Package Manager", "Dev Debug Logs", "AI Tool Cache", "Other"]
              },
              "regenerates_automatically": { "type": "boolean" },
              "reason": { "type": "string" }
            }
          }
        }
        """
    }
}

// Process results use the shared `ProcessResult` (defined in DevToolsModule.swift,
// same Core module) rather than a duplicate type.

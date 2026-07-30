import Foundation

/// Resolves the `docker` CLI across install layouts. The old code hardcoded
/// `/usr/local/bin/docker` (Intel Homebrew) in several spots, so disk-usage and
/// `docker info` probes silently no-op'd on Apple Silicon, where Homebrew lives
/// at `/opt/homebrew`. Checks each candidate for existence and returns the first.
enum DockerCLI {
    /// Docker Desktop's bundled CLI — the only location outside Homebrew.
    static let dockerDesktopPath = "/Applications/Docker.app/Contents/Resources/bin/docker"

    /// First docker binary that actually exists — Homebrew under either prefix
    /// (Intel `/usr/local` or Apple Silicon `/opt/homebrew`, resolved by the
    /// shared `HomebrewPaths`), else the Docker Desktop bundle — or nil.
    static var path: String? {
        if let brewDocker = HomebrewPaths.toolPath("docker") { return brewDocker }
        return FileManager.default.fileExists(atPath: dockerDesktopPath) ? dockerDesktopPath : nil
    }

    /// Parse a complete Docker size token (e.g. "1.5GB", "256M", "512kB")
    /// into bytes. Docker's SI labels use powers of 1000; explicit IEC labels
    /// use powers of 1024. Unknown, missing, or malformed units fail closed.
    static func parseBytes(_ str: String) -> Int64 {
        parseVerifiedBytes(str) ?? 0
    }

    /// Optional form used when cleanup must distinguish a real `0B` value from
    /// malformed external output before allowing a destructive Docker action.
    static func parseVerifiedBytes(_ str: String) -> Int64? {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let unitStart = trimmed.firstIndex { !$0.isNumber && $0 != "." } ?? trimmed.endIndex
        let number = trimmed[..<unitStart]
        let unit = trimmed[unitStart...]
        guard number.first?.isNumber == true,
              number.last?.isNumber == true,
              number.filter({ $0 == "." }).count <= 1,
              !unit.isEmpty,
              unit.allSatisfy(\.isLetter),
              let value = Double(number),
              value.isFinite,
              value >= 0,
              let multiplier = sizeMultipliers[String(unit).uppercased()]
        else { return nil }

        let bytes = value * multiplier
        // Docker output is external input. Reject non-finite/out-of-range values
        // instead of trapping during Double-to-Int64 conversion.
        guard bytes.isFinite, bytes >= 0, bytes < Double(Int64.max) else { return nil }
        return Int64(bytes)
    }

    private static let sizeMultipliers: [String: Double] = [
        "B": 1,
        "K": 1_000,
        "KB": 1_000,
        "M": 1_000_000,
        "MB": 1_000_000,
        "G": 1_000_000_000,
        "GB": 1_000_000_000,
        "T": 1_000_000_000_000,
        "TB": 1_000_000_000_000,
        "P": 1_000_000_000_000_000,
        "PB": 1_000_000_000_000_000,
        "KIB": 1_024,
        "MIB": 1_048_576,
        "GIB": 1_073_741_824,
        "TIB": 1_099_511_627_776,
        "PIB": 1_125_899_906_842_624,
    ]
}

typealias DockerCommandRunner = @Sendable (_ executable: String, _ arguments: [String]) async throws -> ProcessResult

/// Module for cleaning Docker resources
struct DockerModule: ScanModule {
    let id = "docker"
    let name = "Docker"
    let description = "Clean Docker containers, images, volumes, and build cache"
    let icon = "shippingbox.fill"

    private let dockerPath: @Sendable () -> String?
    private let commandRunner: DockerCommandRunner
    private static let diskUsageArguments = ["system", "df", "--format", "{{json .}}"]

    private static let actionCategories: [(action: DockerCleanupAction, dfType: String)] = [
        (.pruneBuildCache, "Build Cache"),
        (.pruneImages, "Images"),
        (.pruneContainers, "Containers"),
        (.pruneVolumes, "Local Volumes"),
    ]

    private static let dockerDFTypeByAction = Dictionary(
        uniqueKeysWithValues: actionCategories.map { ($0.action, $0.dfType) }
    )

    // Containers run last because removing them can make images or volumes
    // newly reclaimable. Earlier actions must not inflate a later prune after
    // the single cleanup-time verification snapshot.
    private static let safeExecutionOrder: [DockerCleanupAction] = [
        .pruneBuildCache,
        .pruneImages,
        .pruneVolumes,
        .pruneContainers,
    ]

    init(
        dockerPath: @escaping @Sendable () -> String? = { DockerCLI.path },
        commandRunner: @escaping DockerCommandRunner = { executable, arguments in
            try await ProcessRunner.run(
                executable: executable,
                arguments: arguments,
                timeout: 300
            )
        }
    ) {
        self.dockerPath = dockerPath
        self.commandRunner = commandRunner
    }

    func scan() async throws -> [CleanupItem] {
        // Check if Docker is installed
        guard isDockerInstalled() else { return [] }

        var items: [CleanupItem] = []

        // Get Docker disk usage
        if let usage = await getDockerDiskUsage() {
            items.append(contentsOf: usage)
        }

        // Docker Desktop VM disk
        let dockerVM = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/com.docker.docker/Data/vms")

        if let item = await scanCacheDirectory(at: dockerVM, moduleName: "Docker VM Disk") {
            items.append(item)
        }

        return items.sorted { $0.size > $1.size }
    }

    private func isDockerInstalled() -> Bool {
        dockerPath() != nil ||
        FileManager.default.fileExists(atPath: "/Applications/Docker.app")
    }

    private func getDockerDiskUsage() async -> [CleanupItem]? {
        guard let reclaimableByType = await getDockerReclaimableByType() else { return nil }
        return Self.actionCategories.compactMap { category in
            let reclaimable = reclaimableByType[category.dfType] ?? 0
            guard reclaimable > 0 else { return nil }
            return CleanupItem(
                id: UUID(),
                action: .docker(category.action),
                size: reclaimable,
                lastModified: nil
            )
        }
    }

    private func getDockerReclaimableByType() async -> [String: Int64]? {
        guard let executable = dockerPath() else { return nil }

        // Summary form (no `-v`) prints one JSON object per resource type,
        // each carrying a human-readable `Reclaimable` field we parse into real
        // per-category byte estimates. ProcessRunner keeps this argv-only and
        // bounded; the injectable runner makes the exact command testable.
        guard let data = await dockerDiskUsageData(executable: executable) else { return nil }

        return Self.parseReclaimableByType(data)
    }

    private func dockerDiskUsageData(executable: String) async -> Data? {
        guard let result = try? await commandRunner(executable, Self.diskUsageArguments),
              result.didSucceed else { return nil }
        return Data(result.output.utf8)
    }

    /// Parse `docker system df --format "{{json .}}"` output — one JSON object
    /// per line per resource type — into reclaimable bytes keyed by `Type`.
    /// The `Reclaimable` field looks like `"1.2GB (80%)"` or `"0B"`; we take the
    /// leading size token.
    static func parseReclaimableByType(_ data: Data) -> [String: Int64] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }

        var result: [String: Int64] = [:]
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = object["Type"] as? String,
                  let reclaimable = object["Reclaimable"] as? String else { continue }
            let sizeToken = reclaimable.split(separator: " ").first.map(String.init) ?? reclaimable
            guard let byteCount = DockerCLI.parseVerifiedBytes(sizeToken) else { continue }
            result[type] = byteCount
        }
        return result
    }

    /// Parse the cleanup-time snapshot strictly. Scan presentation may skip a
    /// malformed row, but destructive cleanup requires every reported row to be
    /// well formed, known, and unique before any selected action can run.
    private static func parseVerifiedReclaimableByType(_ data: Data) -> [String: Int64]? {
        guard let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let knownTypes = Set(actionCategories.map(\.dfType))
        var result: [String: Int64] = [:]
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = object["Type"] as? String,
                  knownTypes.contains(type),
                  result[type] == nil,
                  let reclaimable = object["Reclaimable"] as? String else { return nil }
            let sizeToken = reclaimable.split(separator: " ").first.map(String.init) ?? reclaimable
            guard let byteCount = DockerCLI.parseVerifiedBytes(sizeToken) else { return nil }
            result[type] = byteCount
        }
        return result.isEmpty ? nil : result
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        var processed = 0
        var freed: Int64 = 0
        var errors: [CleanupError] = []
        var candidates: [(item: CleanupItem, action: DockerCleanupAction)] = []

        for item in items where item.module == id {
            guard case .action(.docker(let action)) = item.target else {
                errors.append(CleanupError(
                    path: item.path,
                    message: "Unsupported Docker cleanup target"
                ))
                continue
            }
            guard item.size > 0 else {
                errors.append(CleanupError(
                    path: item.path,
                    message: "Docker cleanup action has no verified reclaimable impact"
                ))
                continue
            }

            if dryRun {
                // item.size is the real reclaimable estimate from `docker system
                // df` (see getDockerDiskUsage), so this is an honest preview,
                // not a synthetic echo. Actual runs below bound Docker's
                // reported reclaimed bytes by this guarded declaration.
                processed += 1
                freed += item.size
                continue
            }

            candidates.append((item, action))
        }

        if dryRun || candidates.isEmpty {
            return CleanupResult(itemsProcessed: processed, bytesFreed: freed, errors: errors)
        }

        var uniqueCandidates: [(item: CleanupItem, action: DockerCleanupAction)] = []
        var selectedActions: Set<DockerCleanupAction> = []
        var hasDuplicate = false
        for candidate in candidates {
            guard selectedActions.insert(candidate.action).inserted else {
                hasDuplicate = true
                errors.append(CleanupError(
                    path: candidate.item.path,
                    message: "Duplicate Docker cleanup action"
                ))
                continue
            }
            uniqueCandidates.append(candidate)
        }

        // Duplicate declarations make the per-action upper bound ambiguous.
        // Reject the whole Docker batch before querying or pruning.
        guard !hasDuplicate else {
            return CleanupResult(itemsProcessed: 0, bytesFreed: 0, errors: errors)
        }

        guard let executable = dockerPath(),
              let liveData = await dockerDiskUsageData(executable: executable),
              let liveImpact = Self.parseVerifiedReclaimableByType(liveData) else {
            errors.append(contentsOf: uniqueCandidates.map {
                CleanupError(
                    path: $0.item.path,
                    message: "Unable to verify current Docker cleanup impact; rescan before cleaning"
                )
            })
            return CleanupResult(itemsProcessed: 0, bytesFreed: 0, errors: errors)
        }

        var verificationErrors: [CleanupError] = []
        for candidate in uniqueCandidates {
            guard let dfType = Self.dockerDFTypeByAction[candidate.action],
                  let currentReclaimable = liveImpact[dfType] else {
                verificationErrors.append(CleanupError(
                    path: candidate.item.path,
                    message: "Unable to verify current Docker cleanup impact; rescan before cleaning"
                ))
                continue
            }
            guard currentReclaimable <= candidate.item.size else {
                verificationErrors.append(CleanupError(
                    path: candidate.item.path,
                    message: "Docker cleanup impact increased after scanning; rescan before cleaning"
                ))
                continue
            }
        }

        // Docker has no atomic measure-and-prune operation. Rechecking once here
        // narrows but cannot eliminate external growth between this snapshot and
        // Docker's command. The guarded declaration remains an upper bound, and
        // containers execute last so this batch cannot inflate a later action.
        guard verificationErrors.isEmpty else {
            errors.append(contentsOf: verificationErrors)
            return CleanupResult(itemsProcessed: 0, bytesFreed: 0, errors: errors)
        }

        let candidatesByAction = Dictionary(uniqueKeysWithValues: uniqueCandidates.map { ($0.action, $0.item) })
        for action in Self.safeExecutionOrder {
            guard let item = candidatesByAction[action] else { continue }
            let result = await runDockerCommand(
                action,
                executable: executable,
                declaredBytes: item.size
            )
            if result.success {
                processed += 1
                // Subprocess output is untrusted and can race the verified
                // snapshot. Never let reporting exceed the guarded declaration,
                // and keep direct module callers overflow-safe as well.
                let boundedFreed = min(result.bytesFreed, item.size)
                let (newFreed, overflow) = freed.addingReportingOverflow(boundedFreed)
                freed = overflow ? Int64.max : newFreed
            } else {
                errors.append(CleanupError(
                    path: item.path,
                    message: result.error ?? "Docker cleanup command failed"
                ))
            }
        }

        return CleanupResult(itemsProcessed: processed, bytesFreed: freed, errors: errors)
    }

    private func runDockerCommand(
        _ action: DockerCleanupAction,
        executable: String,
        declaredBytes: Int64
    ) async -> (success: Bool, bytesFreed: Int64, error: String?) {
        // Containers / volumes: enumerate concrete Docker IDs/names, validate
        // them, then remove by id. Build cache / dangling images still use the
        // fixed native prune argv (no stable per-layer list).
        if let listArgs = action.listArguments {
            return await runEnumeratedDockerRemoval(
                action: action,
                listArguments: listArgs,
                executable: executable,
                declaredBytes: declaredBytes
            )
        }

        do {
            let result = try await commandRunner(executable, action.arguments)
            let bytes = Self.parseReclaimedBytes(result.output)
            let error = result.didSucceed
                ? nil
                : (result.error.isEmpty ? "Docker cleanup command failed" : result.error)
            return (result.didSucceed, bytes, error)
        } catch {
            return (false, 0, error.localizedDescription)
        }
    }

    private func runEnumeratedDockerRemoval(
        action: DockerCleanupAction,
        listArguments: [String],
        executable: String,
        declaredBytes: Int64
    ) async -> (success: Bool, bytesFreed: Int64, error: String?) {
        do {
            let listResult = try await commandRunner(executable, listArguments)
            guard listResult.didSucceed else {
                let message = listResult.error.isEmpty
                    ? "Docker list command failed"
                    : listResult.error
                return (false, 0, message)
            }

            let ids = Self.sanitizedDockerIDs(from: listResult.output, for: action)
            guard !ids.isEmpty else {
                // Nothing to remove — treat as successful zero-byte reclaim.
                return (true, 0, nil)
            }
            guard let removeArgs = action.removeArguments(forIDs: ids) else {
                return (false, 0, "Unsupported Docker removal action")
            }

            let removeResult = try await commandRunner(executable, removeArgs)
            if removeResult.didSucceed {
                // List-then-rm does not print "Total reclaimed space"; credit
                // the verified scan-time declaration (caller also min-bounds).
                return (true, declaredBytes, nil)
            }
            let message = removeResult.error.isEmpty
                ? "Docker remove command failed"
                : removeResult.error
            return (false, 0, message)
        } catch {
            return (false, 0, error.localizedDescription)
        }
    }

    /// Accept only Docker-shaped container hashes or volume names so argv never
    /// carries path-like or shell-metacharacter content from untrusted streams.
    static func sanitizedDockerIDs(from output: String, for action: DockerCleanupAction) -> [String] {
        let tokens = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        switch action {
        case .pruneContainers:
            // 12–64 hex chars (short or full container id)
            return tokens.filter(isDockerContainerID)
        case .pruneVolumes:
            // Docker volume names: alnum start, then alnum/dash/underscore/dot
            return tokens.filter(isDockerVolumeName)
        case .pruneBuildCache, .pruneImages:
            return []
        }
    }

    static func isDockerContainerID(_ token: String) -> Bool {
        guard (12...64).contains(token.count) else { return false }
        return token.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }
    }

    static func isDockerVolumeName(_ token: String) -> Bool {
        guard (1...128).contains(token.count),
              let first = token.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first)
        else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
        return token.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func parseReclaimedBytes(_ output: String) -> Int64 {
        guard let range = output.range(of: "reclaimed space: ", options: .caseInsensitive) else {
            return 0
        }
        let token = output[range.upperBound...]
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init) ?? ""
        return DockerCLI.parseBytes(token)
    }
}

// MARK: - Docker Info

struct DockerInfo {
    var isInstalled: Bool = false
    var isRunning: Bool = false
    var containers: Int = 0
    var images: Int = 0
    var volumes: Int = 0
    var buildCacheSize: Int64 = 0
    var totalSize: Int64 = 0

    var formattedTotalSize: String {
        totalSize.formattedFileSize
    }

    static func current(
        dockerPath: @Sendable () -> String? = { DockerCLI.path },
        commandRunner: DockerCommandRunner = { executable, arguments in
            try await ProcessRunner.run(
                executable: executable,
                arguments: arguments,
                timeout: 30
            )
        }
    ) async -> DockerInfo {
        var info = DockerInfo()

        // Check if Docker is installed
        guard let executable = dockerPath() else { return info }
        info.isInstalled = true

        // The daemon probe is best-effort. ProcessRunner bounds a wedged Docker
        // daemon and drains both pipes; any launch, timeout, or exit failure
        // preserves the existing "installed but not running" result.
        guard let ping = try? await commandRunner(executable, ["info"]),
              ping.didSucceed else { return info }
        info.isRunning = true

        // Get counts
        info.containers = await getDockerCount(
            ["container", "ls", "-aq"],
            executable: executable,
            commandRunner: commandRunner
        )
        info.images = await getDockerCount(
            ["image", "ls", "-q"],
            executable: executable,
            commandRunner: commandRunner
        )
        info.volumes = await getDockerCount(
            ["volume", "ls", "-q"],
            executable: executable,
            commandRunner: commandRunner
        )

        return info
    }

    private static func getDockerCount(
        _ arguments: [String],
        executable: String,
        commandRunner: DockerCommandRunner
    ) async -> Int {
        guard let result = try? await commandRunner(executable, arguments),
              result.didSucceed else { return 0 }
        return result.output.split(separator: "\n").count
    }
}

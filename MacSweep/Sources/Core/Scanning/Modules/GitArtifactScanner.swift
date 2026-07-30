import Foundation

// MARK: - Git Artifact Discovery

enum GitCleanupKind: String, Sendable {
    case worktree = "Worktree"
    case branch = "Branch"

    var icon: String {
        switch self {
        case .worktree: return "folder.badge.gearshape"
        case .branch: return "arrow.triangle.branch"
        }
    }
}

struct GitCleanupItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: GitCleanupKind
    let repositoryPath: URL
    let displayPath: URL?
    let branchName: String?
    let size: Int64
    let lastActivity: Date?
    let reason: String
    let commandPreview: String

    init(
        id: UUID = UUID(),
        kind: GitCleanupKind,
        repositoryPath: URL,
        displayPath: URL?,
        branchName: String?,
        size: Int64,
        lastActivity: Date?,
        reason: String,
        commandPreview: String
    ) {
        self.id = id
        self.kind = kind
        self.repositoryPath = repositoryPath
        self.displayPath = displayPath
        self.branchName = branchName
        self.size = size
        self.lastActivity = lastActivity
        self.reason = reason
        self.commandPreview = commandPreview
    }

    var name: String {
        switch kind {
        case .worktree:
            return displayPath?.lastPathComponent ?? "Git worktree"
        case .branch:
            return branchName ?? "Git branch"
        }
    }

    var formattedSize: String {
        guard size > 0 else { return "No disk data" }
        return size.formattedFileSize
    }

    var timeSinceActivity: String? {
        guard let lastActivity else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastActivity, relativeTo: Date())
    }
}

struct GitCleanupResult: Sendable {
    let itemsProcessed: Int
    let bytesFreed: Int64
    let errors: [CleanupError]
}

struct GitToolStatus: Sendable {
    let gitPath: String?
    let ghPath: String?
    let ghAuthenticated: Bool

    var canUseGitHubCLI: Bool {
        ghPath != nil && ghAuthenticated
    }
}

struct GitArtifactScanner: Sendable {
    var searchPaths: [URL]
    var maxDepth: Int
    var staleInterval: TimeInterval
    var includeGitHubState: Bool

    init(
        searchPaths: [URL] = [FileManager.default.homeDirectoryForCurrentUser],
        maxDepth: Int = 5,
        staleInterval: TimeInterval = 14 * 24 * 60 * 60,
        includeGitHubState: Bool = true
    ) {
        self.searchPaths = searchPaths
        self.maxDepth = maxDepth
        self.staleInterval = staleInterval
        self.includeGitHubState = includeGitHubState
    }

    func toolStatus() async -> GitToolStatus {
        let git = Self.executablePath(for: "git")
        let gh = Self.executablePath(for: "gh")
        let ghAuthenticated: Bool
        if gh != nil {
            ghAuthenticated = await Self.run(["gh", "auth", "status"]).status == 0
        } else {
            ghAuthenticated = false
        }
        return GitToolStatus(gitPath: git, ghPath: gh, ghAuthenticated: ghAuthenticated)
    }

    func discoverStaleArtifacts() async -> [GitCleanupItem] {
        guard Self.executablePath(for: "git") != nil else { return [] }

        let status = await toolStatus()
        let roots = discoverRepositoryRoots()
        var seenCommonDirectories = Set<String>()
        var items: [GitCleanupItem] = []

        for root in roots {
            guard let repository = await Self.repository(at: root) else { continue }
            guard seenCommonDirectories.insert(repository.commonDirectory.path).inserted else { continue }

            let checkedOutBranches = await Self.checkedOutBranches(in: repository.root)
            let staleWorktrees = await discoverStaleWorktrees(
                in: repository,
                checkedOutBranches: checkedOutBranches,
                ghAvailable: status.canUseGitHubCLI
            )
            let staleBranches = await discoverStaleBranches(
                in: repository,
                checkedOutBranches: checkedOutBranches,
                ghAvailable: status.canUseGitHubCLI
            )

            items.append(contentsOf: staleWorktrees)
            items.append(contentsOf: staleBranches)
        }

        return items.sorted {
            if $0.kind.rawValue == $1.kind.rawValue {
                return $0.size > $1.size
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    private func discoverRepositoryRoots() -> [URL] {
        var roots: [URL] = []
        var seen = Set<String>()

        for path in candidateSearchPaths() {
            for root in Self.repositoryRoots(in: path, maxDepth: maxDepth, skipHidden: path.lastPathComponent != ".codex") {
                let standardized = root.standardizedFileURL.path
                if seen.insert(standardized).inserted {
                    roots.append(root)
                }
            }
        }

        return roots
    }

    private func candidateSearchPaths() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let hiddenWorktreeRoots = [
            home.appending(path: ".codex/worktrees", directoryHint: .isDirectory),
            home.appending(path: ".claude/worktrees", directoryHint: .isDirectory),
            home.appending(path: ".agents/worktrees", directoryHint: .isDirectory)
        ]

        return (searchPaths + hiddenWorktreeRoots).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private func discoverStaleWorktrees(
        in repository: GitRepository,
        checkedOutBranches: Set<String>,
        ghAvailable: Bool
    ) async -> [GitCleanupItem] {
        let entries = Self.parseWorktreeList(
            await Self.run(["git", "-C", repository.root.path, "worktree", "list", "--porcelain"]).output
        )
        guard !entries.isEmpty else { return [] }

        var items: [GitCleanupItem] = []
        for (index, entry) in entries.enumerated() {
            guard index > 0 else { continue } // never remove the main worktree
            guard let path = entry.path else { continue }
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            guard await Self.isCleanWorkingTree(path) else { continue }
            // Don't surface a worktree as clean/removable if it holds gitignored
            // content (secrets, local DBs) that `git worktree remove` would
            // permanently destroy.
            guard !(await Self.worktreeHasValuableIgnoredContent(at: path)) else { continue }

            let branch = entry.branchName
            let lastActivity = await Self.commitDate(for: entry.head, in: repository.root)
                ?? Self.lastModificationDate(for: path)
            guard isStale(lastActivity) else { continue }

            let staleReason: String?
            if let branch {
                if Self.isProtectedBranch(branch) || branch == repository.defaultBranch {
                    continue
                }
                let branchState = await Self.branchRemoteState(
                    branch: branch,
                    repository: repository,
                    ghAvailable: ghAvailable && includeGitHubState
                )
                guard branchState.isSafeToClean else { continue }
                staleReason = branchState.reason
            } else if Self.isEphemeralWorktree(path) {
                staleReason = "Detached worktree in an ephemeral agent worktree root"
            } else {
                continue
            }

            let size = (try? await DiskAnalyzer.directorySize(at: path)) ?? 0
            items.append(GitCleanupItem(
                kind: .worktree,
                repositoryPath: repository.root,
                displayPath: path,
                branchName: branch,
                size: size,
                lastActivity: lastActivity,
                reason: staleReason ?? "Clean worktree with no recent activity",
                commandPreview: "git -C \(Self.shellQuoted(repository.root.path)) worktree remove \(Self.shellQuoted(path.path))"
            ))
        }

        return items
    }

    private func discoverStaleBranches(
        in repository: GitRepository,
        checkedOutBranches: Set<String>,
        ghAvailable: Bool
    ) async -> [GitCleanupItem] {
        let rows = await Self.branchRows(in: repository.root)
        guard !rows.isEmpty else { return [] }

        var items: [GitCleanupItem] = []
        for row in rows {
            let branch = row.name
            guard branch != repository.currentBranch else { continue }
            guard branch != repository.defaultBranch else { continue }
            guard !Self.isProtectedBranch(branch) else { continue }
            guard !checkedOutBranches.contains(branch) else { continue }
            guard row.worktreePath == nil || row.worktreePath?.isEmpty == true else { continue }
            guard isStale(row.lastCommitDate) else { continue }

            let branchState = await Self.branchRemoteState(
                branch: branch,
                repository: repository,
                branchRow: row,
                ghAvailable: ghAvailable && includeGitHubState
            )
            guard branchState.isSafeToClean else { continue }

            items.append(GitCleanupItem(
                kind: .branch,
                repositoryPath: repository.root,
                displayPath: repository.root,
                branchName: branch,
                size: 0,
                lastActivity: row.lastCommitDate,
                reason: branchState.reason,
                commandPreview: "git -C \(Self.shellQuoted(repository.root.path)) branch -d \(Self.shellQuoted(branch))"
            ))
        }

        return items
    }

    private func isStale(_ date: Date?) -> Bool {
        guard let date else { return false }
        return Date().timeIntervalSince(date) >= staleInterval
    }

    static func repositoryRoots(in baseURL: URL, maxDepth: Int, skipHidden: Bool) -> [URL] {
        var roots: [URL] = []
        let options: FileManager.DirectoryEnumerationOptions = skipHidden
            ? [.skipsHiddenFiles, .skipsPackageDescendants]
            : [.skipsPackageDescendants]

        if isRepositoryRoot(baseURL) {
            roots.append(baseURL)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: options
        ) else { return roots }

        while let url = enumerator.nextObject() as? URL {
            let depth = url.pathComponents.count - baseURL.pathComponents.count
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }

            let name = url.lastPathComponent
            if shouldSkipDirectory(named: name) {
                enumerator.skipDescendants()
                continue
            }

            if isRepositoryRoot(url) {
                roots.append(url)
                enumerator.skipDescendants()
            }
        }

        return roots
    }

    static func parseWorktreeList(_ output: String) -> [GitWorktreeEntry] {
        var entries: [GitWorktreeEntry] = []
        var current = GitWorktreeEntry()

        func flush() {
            if current.path != nil || current.head != nil || current.branchReference != nil {
                entries.append(current)
            }
            current = GitWorktreeEntry()
        }

        for line in output.components(separatedBy: .newlines) {
            if line.isEmpty {
                flush()
                continue
            }
            if let value = line.removingPrefix("worktree ") {
                if current.path != nil {
                    flush()
                }
                current.path = URL(fileURLWithPath: value)
            } else if let value = line.removingPrefix("HEAD ") {
                current.head = value
            } else if let value = line.removingPrefix("branch ") {
                current.branchReference = value
            } else if line == "detached" {
                current.isDetached = true
            } else if let value = line.removingPrefix("prunable ") {
                current.prunableReason = value
            }
        }
        flush()

        return entries
    }

    static func branchRows(in repositoryRoot: URL) async -> [GitBranchRow] {
        let format = "%(refname:short)%09%(committerdate:iso8601-strict)%09"
            + "%(upstream:short)%09%(upstream:track)%09%(worktreepath)"
        let result = await run(["git", "-C", repositoryRoot.path, "for-each-ref", "refs/heads", "--format=\(format)"])
        guard result.status == 0 else { return [] }
        return parseBranchRows(result.output)
    }

    static func parseBranchRows(_ output: String) -> [GitBranchRow] {
        output.components(separatedBy: .newlines).compactMap { line in
            guard !line.isEmpty else { return nil }
            let parts = line.components(separatedBy: "\t")
            guard let name = parts.first, !name.isEmpty else { return nil }
            return GitBranchRow(
                name: name,
                lastCommitDate: parts.count > 1 ? parseGitDate(parts[1]) : nil,
                upstream: parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil,
                tracking: parts.count > 3 && !parts[3].isEmpty ? parts[3] : nil,
                worktreePath: parts.count > 4 && !parts[4].isEmpty ? parts[4] : nil
            )
        }
    }

    static func isProtectedBranch(_ branch: String) -> Bool {
        let exact: Set<String> = ["main", "master", "develop", "dev", "trunk", "production", "staging"]
        if exact.contains(branch) { return true }
        return branch.hasPrefix("release/") || branch.hasPrefix("hotfix/")
    }

    private static func repository(at root: URL) async -> GitRepository? {
        let topLevel = await run(["git", "-C", root.path, "rev-parse", "--show-toplevel"])
        guard topLevel.status == 0 else { return nil }
        let repositoryRoot = URL(fileURLWithPath: topLevel.output.trimmingCharacters(in: .whitespacesAndNewlines))
            .standardizedFileURL

        let common = await run(["git", "-C", repositoryRoot.path, "rev-parse", "--git-common-dir"])
        guard common.status == 0 else { return nil }
        let commonText = common.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let commonDirectory: URL
        if commonText.hasPrefix("/") {
            commonDirectory = URL(fileURLWithPath: commonText).standardizedFileURL
        } else {
            commonDirectory = repositoryRoot.appending(path: commonText).standardizedFileURL
        }

        let defaultInfo = await defaultBranch(in: repositoryRoot)
        let current = await run(["git", "-C", repositoryRoot.path, "branch", "--show-current"])
            .output
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return GitRepository(
            root: repositoryRoot,
            commonDirectory: commonDirectory,
            defaultBranch: defaultInfo.branch,
            defaultReference: defaultInfo.reference,
            currentBranch: current.isEmpty ? nil : current
        )
    }

    private static func defaultBranch(in repositoryRoot: URL) async -> (branch: String?, reference: String?) {
        let originHead = await run([
            "git", "-C", repositoryRoot.path,
            "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"
        ])
            .output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !originHead.isEmpty {
            let branch = originHead.replacingOccurrences(of: "origin/", with: "")
            if await localBranchExists(branch, in: repositoryRoot) {
                return (branch, branch)
            }
            return (branch, originHead)
        }

        // `for where` cannot suspend while evaluating its predicate.
        // swiftlint:disable for_where
        for candidate in ["main", "master", "trunk", "develop"] {
            if await localBranchExists(candidate, in: repositoryRoot) {
                return (candidate, candidate)
            }
        }
        // swiftlint:enable for_where

        return (nil, nil)
    }

    private static func localBranchExists(_ branch: String, in repositoryRoot: URL) async -> Bool {
        await run([
            "git", "-C", repositoryRoot.path,
            "show-ref", "--verify", "--quiet", "refs/heads/\(branch)"
        ]).status == 0
    }

    private static func checkedOutBranches(in repositoryRoot: URL) async -> Set<String> {
        let result = await run(["git", "-C", repositoryRoot.path, "worktree", "list", "--porcelain"])
        return Set(parseWorktreeList(result.output).compactMap(\.branchName))
    }

    private static func branchRemoteState(
        branch: String,
        repository: GitRepository,
        branchRow: GitBranchRow? = nil,
        ghAvailable: Bool
    ) async -> BranchStaleState {
        if branchRow?.tracking?.contains("[gone]") == true {
            return BranchStaleState(isSafeToClean: true, reason: "Upstream branch is gone")
        }

        if let defaultReference = repository.defaultReference,
           await run([
               "git", "-C", repository.root.path,
               "merge-base", "--is-ancestor", branch, defaultReference
           ]).status == 0 {
            return BranchStaleState(isSafeToClean: true, reason: "Merged into \(defaultReference)")
        }

        if ghAvailable, let prState = await githubPRState(branch: branch, repositoryRoot: repository.root) {
            switch prState {
            case .merged:
                return BranchStaleState(isSafeToClean: true, reason: "GitHub pull request is merged")
            case .closed:
                return BranchStaleState(isSafeToClean: true, reason: "GitHub pull request is closed")
            case .open:
                return BranchStaleState(isSafeToClean: false, reason: "GitHub pull request is still open")
            }
        }

        return BranchStaleState(isSafeToClean: false, reason: "Branch is not proven merged or closed")
    }

    private static func githubPRState(branch: String, repositoryRoot: URL) async -> GitHubPRState? {
        let result = await run([
            "gh", "pr", "list",
            "--head", branch,
            "--state", "all",
            "--json", "state,mergedAt,closedAt",
            "--limit", "1"
        ], currentDirectory: repositoryRoot)
        guard result.status == 0, let data = result.output.data(using: .utf8) else { return nil }
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = rows.first,
              let state = first["state"] as? String else { return nil }

        if let mergedAt = first["mergedAt"] as? String, !mergedAt.isEmpty {
            return .merged
        }
        if state.caseInsensitiveCompare("merged") == .orderedSame {
            return .merged
        }
        if state.caseInsensitiveCompare("closed") == .orderedSame {
            return .closed
        }
        if state.caseInsensitiveCompare("open") == .orderedSame {
            return .open
        }
        return nil
    }

    private static func commitDate(for commit: String?, in repositoryRoot: URL) async -> Date? {
        guard let commit, !commit.isEmpty else { return nil }
        let result = await run(["git", "-C", repositoryRoot.path, "show", "-s", "--format=%cI", commit])
        guard result.status == 0 else { return nil }
        return parseGitDate(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func lastModificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func isCleanWorkingTree(_ url: URL) async -> Bool {
        let result = await run(["git", "-C", url.path, "status", "--porcelain", "--ignore-submodules"])
        return result.status == 0
            && result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True if the worktree holds gitignored content that `git worktree remove`
    /// would permanently destroy.
    ///
    /// `git worktree remove` (and git's own cleanliness guard) ignore gitignored
    /// files, and `git status --porcelain` doesn't list them — only `--ignored`
    /// does. So a worktree whose only extra content is a gitignored `.env` or a
    /// local SQLite DB reads as "clean" and would be deleted permanently (not to
    /// Trash), never passing `SafetyChecker`. We refuse when any ignored entry
    /// has nonzero size on disk; empty ignored placeholders (e.g. an empty
    /// `dist/`) don't count. Fails closed: if git can't report, we treat the
    /// tree as unsafe to delete.
    static func worktreeHasValuableIgnoredContent(at url: URL) async -> Bool {
        let result = await run([
            "git", "-C", url.path,
            "status", "--porcelain=v1", "-z", "--ignored", "--ignore-submodules"
        ])
        guard result.status == 0 else { return true }

        // `-z` emits paths verbatim and terminates each record with NUL, so
        // quotes, backslashes, tabs, newlines, and non-ASCII characters are not
        // C-quoted or confused with a record boundary.
        for record in result.output.split(separator: "\0") {
            guard record.hasPrefix("!! ") else { continue }  // "!!" marks ignored entries
            let entry = String(record.dropFirst(3))
            guard !entry.isEmpty else { continue }
            if pathHasNonzeroContent(url.appending(path: entry)) { return true }
        }
        return false
    }

    /// Whether `url` is a nonempty file, or a directory containing at least one
    /// nonempty regular file. Directories are enumerated lazily and the walk
    /// short-circuits on the first nonzero-size file.
    private static func pathHasNonzeroContent(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }

        if !isDirectory.boolValue {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return size > 0
        }

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else {
            return true  // can't enumerate — be conservative
        }
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 { return true }
        }
        return false
    }

    private static func isEphemeralWorktree(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return path.hasPrefix(home + "/.codex/worktrees/")
            || path.hasPrefix(home + "/.claude/worktrees/")
            || path.hasPrefix(home + "/.agents/worktrees/")
    }

    private static func isRepositoryRoot(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: ".git").path)
    }

    private static func shouldSkipDirectory(named name: String) -> Bool {
        let skipped: Set<String> = [
            ".git", ".svn", "node_modules", "vendor", ".build", "build",
            "Pods", "DerivedData", "Library", ".Trash", ".Trashes"
        ]
        return skipped.contains(name)
    }

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

    static func run(
        _ arguments: [String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 10
    ) async -> ProcessResult {
        guard let command = arguments.first,
              let executable = executablePath(for: command) else {
            return ProcessResult(status: 127, output: "", error: "Command not found")
        }

        do {
            let result = try await ProcessRunner.run(
                executable: executable,
                arguments: Array(arguments.dropFirst()),
                currentDirectory: currentDirectory,
                timeout: timeout
            )
            return strictUTF8Result(result)
        } catch ProcessRunnerError.timedOut(_, let partialResult) {
            let timeoutError = "Subprocess timed out after \(timeout)s"
            let error = partialResult.error.trimmingCharacters(in: .whitespacesAndNewlines)
            return strictUTF8Result(ProcessResult(
                status: 124,
                output: partialResult.output,
                error: error.isEmpty ? timeoutError : "\(error)\n\(timeoutError)",
                outputWasValidUTF8: partialResult.outputWasValidUTF8
            ))
        } catch {
            return ProcessResult(status: 127, output: "", error: error.localizedDescription)
        }
    }

    /// Git `-z` output can contain raw filename bytes. Never turn a decode
    /// failure into replacement characters and apparent success: deletion guards
    /// rely on the subprocess status to fail closed.
    private static func strictUTF8Result(_ result: ProcessResult) -> ProcessResult {
        guard result.outputWasValidUTF8 else {
            let decodeError = "Subprocess stdout was not valid UTF-8"
            let error = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            return ProcessResult(
                status: result.status == 0 ? -1 : result.status,
                output: "",
                error: error.isEmpty ? decodeError : "\(error)\n\(decodeError)",
                outputWasValidUTF8: false
            )
        }
        return result
    }

    private static func parseGitDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) {
            return date
        }

        let formatter = DateFormatter.posixShellDate(format: "yyyy-MM-dd HH:mm:ss Z")
        return formatter.date(from: trimmed)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

actor GitArtifactCleaner {
    func clean(items: [GitCleanupItem], dryRun: Bool) async -> GitCleanupResult {
        var processed = 0
        var freed: Int64 = 0
        var errors: [CleanupError] = []

        for item in items {
            if dryRun {
                processed += 1
                freed += item.size
                continue
            }

            switch item.kind {
            case .worktree:
                guard let path = item.displayPath else {
                    errors.append(CleanupError(path: item.repositoryPath, message: "Missing worktree path"))
                    continue
                }

                let worktreeList = await GitArtifactScanner.run([
                    "git", "-C", item.repositoryPath.path,
                    "worktree", "list", "--porcelain"
                ])
                guard GitArtifactScanner.parseWorktreeList(worktreeList.output)
                    .contains(where: { $0.path?.standardizedFileURL.path == path.standardizedFileURL.path }) else {
                    errors.append(CleanupError(path: path, message: "Worktree is no longer registered"))
                    continue
                }

                let worktreeStatus = await GitArtifactScanner.run([
                    "git", "-C", path.path,
                    "status", "--porcelain", "--ignore-submodules"
                ])
                guard worktreeStatus.status == 0,
                      worktreeStatus.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    errors.append(CleanupError(
                        path: path,
                        message: "Worktree status could not be verified or has local changes"
                    ))
                    continue
                }

                // `git status --porcelain` and `git worktree remove` both ignore
                // gitignored files, so a worktree whose only extra content is a
                // gitignored `.env` or local DB would be permanently destroyed.
                // Refuse when valuable ignored content is present.
                guard !(await GitArtifactScanner.worktreeHasValuableIgnoredContent(at: path)) else {
                    errors.append(CleanupError(
                        path: path,
                        message: "Worktree contains gitignored files; skipped to avoid permanent data loss"
                    ))
                    continue
                }

                let result = await GitArtifactScanner.run([
                    "git", "-C", item.repositoryPath.path,
                    "worktree", "remove", path.path
                ])
                if result.status == 0 {
                    processed += 1
                    freed += item.size
                } else {
                    errors.append(CleanupError(
                        path: path,
                        message: result.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "git worktree remove failed"
                            : result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }

            case .branch:
                guard let branch = item.branchName else {
                    errors.append(CleanupError(path: item.repositoryPath, message: "Missing branch name"))
                    continue
                }
                guard !GitArtifactScanner.isProtectedBranch(branch) else {
                    errors.append(CleanupError(path: item.repositoryPath, message: "Protected branch"))
                    continue
                }

                let result = await GitArtifactScanner.run([
                    "git", "-C", item.repositoryPath.path,
                    "branch", "-d", branch
                ])
                if result.status == 0 {
                    processed += 1
                } else {
                    errors.append(CleanupError(
                        path: item.repositoryPath,
                        message: result.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "git branch -d failed"
                            : result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
            }
        }

        return GitCleanupResult(itemsProcessed: processed, bytesFreed: freed, errors: errors)
    }
}

private struct GitRepository: Sendable {
    let root: URL
    let commonDirectory: URL
    let defaultBranch: String?
    let defaultReference: String?
    let currentBranch: String?
}

struct GitWorktreeEntry: Sendable, Equatable {
    var path: URL?
    var head: String?
    var branchReference: String?
    var isDetached = false
    var prunableReason: String?

    var branchName: String? {
        guard let branchReference else { return nil }
        let prefix = "refs/heads/"
        if branchReference.hasPrefix(prefix) {
            return String(branchReference.dropFirst(prefix.count))
        }
        return branchReference
    }
}

struct GitBranchRow: Sendable, Equatable {
    let name: String
    let lastCommitDate: Date?
    let upstream: String?
    let tracking: String?
    let worktreePath: String?
}

private struct BranchStaleState: Sendable {
    let isSafeToClean: Bool
    let reason: String
}

private enum GitHubPRState: Sendable {
    case open
    case closed
    case merged
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

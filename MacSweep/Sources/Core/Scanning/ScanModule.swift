import Foundation

/// Protocol for all cleanup modules
protocol ScanModule: Identifiable, Sendable {
    var id: String { get }
    var name: String { get }
    var description: String { get }
    var icon: String { get }

    /// Scan for items that can be cleaned
    func scan() async throws -> [CleanupItem]

    /// Clean the specified items
    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult
}

extension ScanModule {
    /// Build a `CleanupItem` for a cache directory if it exists and clears the
    /// size `threshold`; returns nil otherwise. Centralizes the
    /// exists → directorySize → size>threshold → CleanupItem idiom that the
    /// package-manager, dev-tools, service-worker, network, cloud, docker, and
    /// browser scanners otherwise repeat inline. Behaviour is identical to the
    /// hand-written blocks.
    ///
    /// - Parameters:
    ///   - threshold: Exclusive lower size bound. The default of `0` preserves
    ///     the original `size > 0` guard; pass e.g. `1024` for a `size > 1024`
    ///     block. The comparison is strict (`size > threshold`), matching every
    ///     migrated `>` site verbatim. A site written as `size >= minimum` maps
    ///     to `threshold: minimum - 1`.
    ///   - safetyCheck: Optional scan-time gate (e.g. CloudCleanupModule's
    ///     `SafetyChecker.validateForScan`). When it returns `false` the
    ///     directory is skipped before its size is computed, exactly as the
    ///     inline `guard …isSafe else { continue }` did.
    ///
    /// Scan-only — the safety-gated deletion path in `clean()` is untouched.
    func scanCacheDirectory(
        at url: URL,
        moduleName displayName: String,
        type: CleanupItem.ItemType = .directory,
        threshold: Int64 = 0,
        safetyCheck: (@Sendable (URL) -> Bool)? = nil
    ) async -> CleanupItem? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let safetyCheck, !safetyCheck(url) { return nil }
        let size = (try? await DiskAnalyzer.directorySize(at: url)) ?? 0
        guard size > threshold else { return nil }
        let lastModified = try? url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        return CleanupItem(
            id: UUID(),
            path: url,
            size: size,
            type: type,
            module: id,
            moduleName: displayName,
            lastModified: lastModified,
            contentModificationDate: lastModified
        )
    }

    /// Shared implementation for modules that clean `CleanupItem`s one by one.
    /// Keeps dry-run accounting, module filtering, and cleanup-time safety checks
    /// consistent while each module supplies its own removal strategy.
    func cleanItems(
        _ items: [CleanupItem],
        dryRun: Bool,
        blockedMessage: String = "Blocked by safety checks",
        errorMessage: @escaping (Error) -> String = { $0.localizedDescription },
        remove: (CleanupItem, SafetyChecker) async throws -> Void
    ) async -> CleanupResult {
        await cleanItemsRecordingActions(
            items,
            dryRun: dryRun,
            blockedMessage: blockedMessage,
            errorMessage: errorMessage
        ) { item, checker in
            try await remove(item, checker)
            return nil
        }
    }

    /// Variant of ``cleanItems(_:dryRun:blockedMessage:errorMessage:remove:)``
    /// for removers whose successful operation determines the factual history
    /// action at cleanup time.
    func cleanItemsRecordingActions(
        _ items: [CleanupItem],
        dryRun: Bool,
        blockedMessage: String = "Blocked by safety checks",
        errorMessage: @escaping (Error) -> String = { $0.localizedDescription },
        remove: (CleanupItem, SafetyChecker) async throws -> CleanupHistoryAction?
    ) async -> CleanupResult {
        var processed = 0
        var freed: Int64 = 0
        var errors: [CleanupError] = []
        var historyActions: [CleanupItem.ID: CleanupHistoryAction] = [:]
        let checker = SafetyChecker()

        for item in items where item.module == id {
            if dryRun {
                processed += 1
                freed += item.size
                continue
            }

            guard case .fileSystem = item.target,
                  checker.validateForCleanup(item, moduleID: id).isSafe else {
                errors.append(CleanupError(
                    path: item.path,
                    message: blockedMessage
                ))
                continue
            }

            do {
                let action = try await remove(item, checker)
                processed += 1
                freed += item.size
                if let action {
                    historyActions[item.id] = action
                }
            } catch {
                errors.append(CleanupError(
                    path: item.path,
                    message: errorMessage(error),
                    underlyingError: error
                ))
            }
        }

        return CleanupResult(
            itemsProcessed: processed,
            bytesFreed: freed,
            errors: errors,
            historyActions: historyActions
        )
    }
}

// MARK: - Cleanup Item

/// A cleanup operation that is intentionally not a filesystem deletion.
///
/// The enum is closed so scanned data can select only actions compiled into the
/// app. It carries no paths or free-form arguments that could be reinterpreted by
/// a subprocess launcher.
enum CleanupAction: Hashable, Sendable {
    case docker(DockerCleanupAction)

    var moduleID: String {
        switch self {
        case .docker: return "docker"
        }
    }

    var displayName: String {
        switch self {
        case .docker(let action): return action.displayName
        }
    }

    var identifier: String {
        switch self {
        case .docker(let action): return action.rawValue
        }
    }

    /// A stable presentation URL for existing UI and error-reporting surfaces.
    /// This is deliberately not a file URL and is never passed to FileManager.
    var presentationURL: URL {
        // moduleID and identifier come exclusively from closed enums, so this
        // constant-form URL cannot fail to parse.
        URL(string: "macsweep-action://\(moduleID)/\(identifier)")!
    }
}

/// The complete allowlist of Docker cleanup operations MacSweep can execute.
enum DockerCleanupAction: String, CaseIterable, Hashable, Sendable {
    case pruneBuildCache = "prune-build-cache"
    case pruneImages = "prune-images"
    case pruneContainers = "prune-containers"
    case pruneVolumes = "prune-volumes"

    var displayName: String {
        switch self {
        case .pruneBuildCache: return "All unused Docker build cache"
        case .pruneImages: return "All dangling Docker images"
        case .pruneContainers: return "All stopped Docker containers"
        case .pruneVolumes: return "All unused Docker volumes"
        }
    }

    /// Fixed argv for the Docker CLI. There is no string-bearing enum case, so
    /// paths, labels, and scan output can never become command arguments.
    ///
    /// Containers and volumes use list-then-remove-by-id so the command stream
    /// enumerates concrete Docker IDs rather than a host-wide opaque prune.
    /// Build cache and dangling images still use Docker's native prune (no
    /// stable per-layer ID listing for those).
    var arguments: [String] {
        switch self {
        case .pruneBuildCache: return ["builder", "prune", "-f"]
        case .pruneImages: return ["image", "prune", "-f"]
        case .pruneContainers: return ["container", "prune", "-f"]
        case .pruneVolumes: return ["volume", "prune", "-f"]
        }
    }

    /// List command used to enumerate concrete targets before remove-by-id.
    var listArguments: [String]? {
        switch self {
        case .pruneContainers: return ["container", "ls", "-aq", "-f", "status=exited"]
        case .pruneVolumes: return ["volume", "ls", "-q", "-f", "dangling=true"]
        case .pruneBuildCache, .pruneImages: return nil
        }
    }

    func removeArguments(forIDs ids: [String]) -> [String]? {
        guard !ids.isEmpty else { return nil }
        switch self {
        case .pruneContainers: return ["container", "rm"] + ids
        case .pruneVolumes: return ["volume", "rm"] + ids
        case .pruneBuildCache, .pruneImages: return nil
        }
    }

    var commandPreview: String {
        switch self {
        case .pruneContainers:
            return "docker container ls -aq -f status=exited && docker container rm <ids>"
        case .pruneVolumes:
            return "docker volume ls -q -f dangling=true && docker volume rm <names>"
        case .pruneBuildCache, .pruneImages:
            return (["docker"] + arguments).joined(separator: " ")
        }
    }

    var impactDescription: String {
        switch self {
        case .pruneBuildCache:
            return "Permanently removes ALL unused Docker build cache on this host via Docker's native prune."
        case .pruneImages:
            return "Permanently removes ALL dangling (untagged) Docker images on this host."
        case .pruneContainers:
            return "Permanently removes ALL stopped containers (enumerated by id, then docker container rm)."
        case .pruneVolumes:
            return "Permanently removes ALL dangling/unused volumes (enumerated by name, then docker volume rm). Volume data cannot be recovered."
        }
    }

    var icon: String {
        switch self {
        case .pruneBuildCache: return "hammer"
        case .pruneImages: return "photo.stack"
        case .pruneContainers: return "cube.box"
        case .pruneVolumes: return "cylinder"
        }
    }
}

struct CleanupItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let target: Target
    let size: Int64
    let module: String
    let moduleName: String
    /// Module-defined activity timestamp used by existing age filters and sort order.
    let lastModified: Date?
    /// Actual filesystem content-modification timestamp when the scanner captures it separately.
    let contentModificationDate: Date?
    let cleanupReviewReason: String?

    enum Target: Hashable, Sendable {
        case fileSystem(path: URL, type: ItemType)
        case action(CleanupAction)
    }

    enum ItemType: String, Sendable {
        case file
        case directory
        case symbolicLink
        case action
    }

    init(
        id: UUID,
        path: URL,
        size: Int64,
        type: ItemType,
        module: String,
        moduleName: String,
        lastModified: Date? = nil,
        contentModificationDate: Date? = nil,
        cleanupReviewReason: String? = nil
    ) {
        self.id = id
        self.target = .fileSystem(path: path, type: type)
        self.size = size
        self.module = module
        self.moduleName = moduleName
        self.lastModified = lastModified
        self.contentModificationDate = contentModificationDate
        self.cleanupReviewReason = cleanupReviewReason
    }

    /// Builds a non-filesystem cleanup finding with canonical ownership and
    /// labeling derived from the closed action enum.
    init(
        id: UUID,
        action: CleanupAction,
        size: Int64,
        lastModified: Date? = nil
    ) {
        self.id = id
        self.target = .action(action)
        self.size = size
        self.module = action.moduleID
        self.moduleName = action.displayName
        self.lastModified = lastModified
        self.contentModificationDate = nil
        self.cleanupReviewReason = nil
    }

    /// Compatibility projection for UI/error surfaces. Action URLs use the
    /// `macsweep-action` scheme and must never be treated as filesystem paths.
    var path: URL {
        switch target {
        case .fileSystem(let path, _): return path
        case .action(let action): return action.presentationURL
        }
    }

    var type: ItemType {
        switch target {
        case .fileSystem(_, let type): return type
        case .action: return .action
        }
    }

    var displayName: String {
        switch target {
        case .fileSystem(let path, _): return path.lastPathComponent
        case .action(let action): return action.displayName
        }
    }

    var formattedSize: String {
        size.formattedFileSize
    }

    var icon: String {
        switch type {
        case .file: return "doc"
        case .directory: return "folder"
        case .symbolicLink: return "link"
        case .action: return "shippingbox"
        }
    }

    func markingCleanupReview(reason: String?) -> CleanupItem {
        guard let reason else { return self }
        switch target {
        case .fileSystem(let path, let type):
            return CleanupItem(
                id: id,
                path: path,
                size: size,
                type: type,
                module: module,
                moduleName: moduleName,
                lastModified: lastModified,
                contentModificationDate: contentModificationDate,
                cleanupReviewReason: reason
            )
        case .action:
            return self
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: CleanupItem, rhs: CleanupItem) -> Bool {
        lhs.id == rhs.id
    }
}

/// Presentation-ready metadata shared by populated cleanup result rows.
///
/// Modules supply the timestamp and fallback rationale because those remain
/// domain-specific, while path, size, custom-reason precedence, and the
/// unavailable-date contract stay consistent across every cleanup surface.
struct CleanupResultEvidence: Equatable, Sendable {
    enum Modification: Equatable, Sendable {
        case date(Date)
        case unavailable
    }

    let path: String
    let formattedSize: String
    let modification: Modification
    let reviewReason: String

    init(
        item: CleanupItem,
        modificationDate: Date?,
        defaultReviewReason: String
    ) {
        path = item.path.path
        formattedSize = item.formattedSize
        modification = modificationDate.map(Modification.date) ?? .unavailable
        reviewReason = item.cleanupReviewReason ?? defaultReviewReason
    }
}

/// A review-only cluster of related personal files with exactly one protected
/// keeper. Feature pages may change the keeper, but cleanup selection must
/// always exclude it so a group can never be emptied accidentally.
struct FileReviewGroup: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let items: [CleanupItem]
    let suggestedKeeperID: CleanupItem.ID
    let suggestionReason: String

    var suggestedCleanupItems: [CleanupItem] {
        items.filter { $0.id != suggestedKeeperID }
    }

    var suggestedCleanupIDs: Set<CleanupItem.ID> {
        Set(suggestedCleanupItems.map(\.id))
    }

    func cleanupIDs(keeping keeperID: CleanupItem.ID) -> Set<CleanupItem.ID> {
        guard items.contains(where: { $0.id == keeperID }) else { return [] }
        return Set(items.lazy.map(\.id).filter { $0 != keeperID })
    }

    func retainingItems(withIDs liveIDs: Set<CleanupItem.ID>) -> FileReviewGroup? {
        let remainingItems = items.filter { liveIDs.contains($0.id) }
        guard remainingItems.count > 1 else { return nil }

        let remainingKeeperID = remainingItems.contains(where: { $0.id == suggestedKeeperID })
            ? suggestedKeeperID
            : remainingItems[0].id
        return FileReviewGroup(
            id: id,
            title: title,
            items: remainingItems,
            suggestedKeeperID: remainingKeeperID,
            suggestionReason: suggestionReason
        )
    }
}

// MARK: - Cleanup Result

struct CleanupResult: Sendable {
    let itemsProcessed: Int
    let bytesFreed: Int64
    let errors: [CleanupError]
    let historyActions: [CleanupItem.ID: CleanupHistoryAction]
    let timestamp: Date

    var formattedBytesFreed: String {
        bytesFreed.formattedFileSize
    }

    var isSuccess: Bool {
        errors.isEmpty
    }

    /// User-facing summary of per-item failures, or nil when everything succeeded.
    var failureSummaryMessage: String? {
        errors.failureSummaryMessage
    }

    init(
        itemsProcessed: Int,
        bytesFreed: Int64,
        errors: [CleanupError] = [],
        historyActions: [CleanupItem.ID: CleanupHistoryAction] = [:]
    ) {
        self.itemsProcessed = itemsProcessed
        self.bytesFreed = bytesFreed
        self.errors = errors
        self.historyActions = historyActions
        self.timestamp = Date()
    }
}

// MARK: - Cleanup Review

/// Stable, UI-independent facts shown before every destructive GUI cleanup.
/// Keeping the aggregation in Core makes the review contract testable and keeps
/// every feature page honest about the cleanup scope it can preview.
struct CleanupReviewSummary: Equatable, Sendable {
    let itemCount: Int
    let totalBytes: Int64
    let moduleCounts: [(name: String, count: Int)]
    let paths: [URL]
    let exceedsConfirmationThreshold: Bool

    init(
        items: [CleanupItem],
        additionalCount: Int = 0,
        additionalBytes: Int64 = 0,
        additionalModules: [String] = [],
        additionalPaths: [URL] = [],
        confirmationThreshold: Int64 = DeletionGuard().confirmationThreshold
    ) {
        let (combinedCount, countOverflow) = items.count.addingReportingOverflow(max(0, additionalCount))
        itemCount = countOverflow ? Int.max : combinedCount
        totalBytes = (items.map(\.size) + [additionalBytes]).reduce(0) { total, bytes in
            let (sum, overflow) = total.addingReportingOverflow(max(0, bytes))
            return overflow ? Int64.max : sum
        }

        var counts = Dictionary(grouping: items, by: \.moduleName).mapValues(\.count)
        for module in additionalModules {
            counts[module, default: 0] += 1
        }
        moduleCounts = counts
            .map { (name: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs.name < rhs.name : lhs.count > rhs.count
            }
        var seenPaths = Set<URL>()
        paths = (items.map(\.path) + additionalPaths).filter {
            seenPaths.insert($0).inserted
        }
        exceedsConfirmationThreshold = totalBytes > confirmationThreshold
    }

    static func == (lhs: CleanupReviewSummary, rhs: CleanupReviewSummary) -> Bool {
        lhs.itemCount == rhs.itemCount
            && lhs.totalBytes == rhs.totalBytes
            && lhs.moduleCounts.elementsEqual(rhs.moduleCounts) {
                $0.name == $1.name && $0.count == $1.count
            }
            && lhs.paths == rhs.paths
            && lhs.exceedsConfirmationThreshold == rhs.exceedsConfirmationThreshold
    }
}

struct CleanupError: Error, Identifiable, Sendable {
    let id: UUID
    let path: URL
    let message: String
    let underlyingError: Error?

    init(id: UUID = UUID(), path: URL, message: String, underlyingError: Error? = nil) {
        self.id = id
        self.path = path
        self.message = message
        self.underlyingError = underlyingError
    }
}

extension Array where Element == CleanupError {
    /// User-facing summary of per-item cleanup failures, or nil when empty.
    /// Wording stays generic on purpose: cleanup errors mix safety vetoes with
    /// ordinary deletion failures, so a blanket "blocked by safety checks" would
    /// mislabel the latter. The first error's own message carries the actual
    /// reason (safety-blocked items say so in their message).
    var failureSummaryMessage: String? {
        guard let first = first else { return nil }
        let itemCount = count == 1 ? "1 item" : "\(count) items"
        return "\(itemCount) couldn't be removed: \(first.message)"
    }
}

// MARK: - Disk Usage

struct DiskUsage: Sendable, Equatable {
    let total: Int64
    let used: Int64
    let free: Int64

    var usedPercentage: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total)
    }

    var freePercentage: Double {
        guard total > 0 else { return 0 }
        return Double(free) / Double(total)
    }

    var formattedUsed: String {
        used.formattedFileSize
    }

    var formattedFree: String {
        free.formattedFileSize
    }

    var formattedTotal: String {
        total.formattedFileSize
    }

    static func current() async -> DiskUsage? {
        let home = FileManager.default.homeDirectoryForCurrentUser

        do {
            let values = try home.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])

            guard let total = values.volumeTotalCapacity,
                  let free = values.volumeAvailableCapacityForImportantUsage
            else { return nil }

            return DiskUsage(
                total: Int64(total),
                used: Int64(total) - free,
                free: free
            )
        } catch {
            return nil
        }
    }
}

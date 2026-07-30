import SwiftUI
import Combine

/// Global application state
@MainActor
final class AppState: ObservableObject {
    // MARK: - Scanning State
    @Published var isScanning = false
    @Published var scanProgress: Double = 0
    @Published var currentScanModule: String?
    @Published var scanResults: [CleanupItem] = []
    @Published var selectedItems: Set<CleanupItem.ID> = []
    @Published var smartCareSummary: SmartCareSummary?
    @Published var scanFailures: [ModuleScanFailure] = []

    /// Last scan failure, surfaced to the UI. Cleared at the start of each scan.
    @Published var lastError: String?

    /// Last deletion failure (cap hit, safety block, or per-item error), surfaced
    /// to the UI separately from scan errors. Cleared at the start of each cleanup.
    @Published var lastDeletionError: String?

    // MARK: - Disk Usage
    @Published var diskUsage: DiskUsage?

    // MARK: - Last Cleanup
    @Published var lastCleanup: CleanupResult?
    @Published var cleanupPerformanceHistory: [CleanupPerformanceEntry] = []

    // MARK: - UI State
    @Published var selectedFeature: Feature = .smartScan
    @Published var showingConfirmation = false
    @Published private(set) var hasFullDiskAccess: Bool

    // MARK: - Menu Bar
    var menuBarIcon: String {
        if isScanning {
            return "sparkles"
        } else if let usage = diskUsage, usage.freePercentage < 0.1 {
            return "exclamationmark.triangle.fill"
        } else {
            return "sparkles.rectangle.stack"
        }
    }

    // MARK: - Engines
    let scanEngine = ScanEngine()
    let safetyChecker = SafetyChecker()
    let assistant = AssistantCoordinator()
    /// One process sampler shared by Dashboard, Optimization, and menu-bar detail
    /// panels so concurrent surfaces don't each spawn a 5s `ps` loop.
    let processMonitor = ProcessMonitor()
    /// One system-metrics monitor for dashboard, menu bar, optimization, and
    /// battery views so they don't each run independent 2s / 30s probe timers.
    let systemMonitor = SystemMonitor()
    private let cleanupPerformanceStore = CleanupPerformanceStore.shared
    private var activeScanTask: Task<Void, Never>?
    private var activeScanID: UUID?
    private var lastScanScope: ScanScope?

    private struct ScanScope {
        let modules: [String]?
        let assistantTargets: [AssistantScanTarget]
    }

    // MARK: - Initialization
    init(initialFullDiskAccess: Bool = FullDiskAccess.hasAccess) {
        hasFullDiskAccess = initialFullDiskAccess
        cleanupPerformanceHistory = cleanupPerformanceStore.history

        Task {
            await refreshDiskUsage()
        }
    }

    // MARK: - Actions

    /// Stop the in-flight scan, if any. The scan modules check
    /// `Task.checkCancellation()` inside their enumeration loops, so this
    /// actually halts the disk walk instead of letting it run to completion.
    /// A queued caller waiting in `startScan` proceeds normally afterwards.
    func cancelScan() {
        activeScanTask?.cancel()
    }

    func quickScan() async {
        guard hasFullDiskAccess else {
            lastError = FullDiskAccessScope.smartCare.actionBlockedMessage
            return
        }

        await startScan(scope: ScanScope(
            modules: SmartCareDefaults.moduleIDs,
            assistantTargets: assistant.enabledTargets
        ))
    }

    func scan(modules: [String]? = nil) async {
        if modules == nil, !hasFullDiskAccess {
            lastError = FullDiskAccessScope.smartCare.actionBlockedMessage
            return
        }

        await startScan(scope: ScanScope(
            modules: modules,
            assistantTargets: modules == nil ? assistant.enabledTargets : []
        ))
    }

    func retryLastScan() async {
        guard hasFullDiskAccess else {
            lastError = FullDiskAccessScope.smartCare.actionBlockedMessage
            return
        }

        guard let lastScanScope else {
            await quickScan()
            return
        }
        await startScan(scope: lastScanScope)
    }

    func deleteSelected(dryRun: Bool = false, confirmedLargeDeletion: Bool = false) async throws -> CleanupResult {
        if !dryRun { lastDeletionError = nil }
        let itemsToDelete = scanResults.filter { selectedItems.contains($0.id) }
        // Re-read the current max-delete-size preference for every cleanup.
        let engine = ScanEngine()

        let result: CleanupResult
        do {
            result = try await engine.clean(
                items: itemsToDelete,
                dryRun: dryRun,
                confirmedLargeDeletion: confirmedLargeDeletion
            )
        } catch {
            // Surface the failure (e.g. the DeletionGuard cap) so callers using
            // `try?` still give the user feedback instead of swallowing it.
            if !dryRun { lastDeletionError = error.localizedDescription }
            throw error
        }

        if !dryRun {
            lastCleanup = result
            recordCleanupPerformance(result)
            // Per-item failures are returned in result.errors (not thrown). Only
            // remove items that actually left disk; keep failed ones in the list
            // rather than silently dropping them.
            let failedPaths = Set(result.errors.map(\.path))
            scanResults.removeAll { selectedItems.contains($0.id) && !failedPaths.contains($0.path) }
            selectedItems = selectedItems.filter { id in scanResults.contains(where: { $0.id == id }) }
            smartCareSummary = scanResults.isEmpty
                ? nil
                : SmartCareAnalyzer().summarize(items: scanResults, diskUsage: diskUsage)
            await refreshDiskUsage()
            if let summary = result.failureSummaryMessage {
                lastDeletionError = summary
            }
        }

        return result
    }

    func refreshDiskUsage() async {
        diskUsage = await DiskUsage.current()
    }

    func refreshFullDiskAccess() {
        hasFullDiskAccess = FullDiskAccess.hasAccess
    }

    func selectAll() {
        selectedItems = Set(scanResults.map(\.id))
    }

    func selectRecommended() {
        selectedItems = smartCareSummary?.recommendedCleanupItemIDs ?? []
    }

    func deselectAll() {
        selectedItems.removeAll()
    }

    func recordCleanupPerformance(_ result: CleanupResult) {
        cleanupPerformanceStore.record(result)
        cleanupPerformanceHistory = cleanupPerformanceStore.history
    }

    func selectItems(withIDs ids: Set<CleanupItem.ID>) {
        selectedItems.formUnion(ids)
    }

    func deselectItems(withIDs ids: Set<CleanupItem.ID>) {
        selectedItems.subtract(ids)
    }

    func toggleSelection(for item: CleanupItem) {
        if selectedItems.contains(item.id) {
            selectedItems.remove(item.id)
        } else {
            selectedItems.insert(item.id)
        }
    }

    var selectedSize: Int64 {
        scanResults.totalSize(selected: selectedItems)
    }

    func feature(for moduleID: String) -> Feature? {
        switch moduleID {
        case AssistantWatchlistModule.moduleID: return .assistant
        case "system-cache": return .systemJunk
        case "mail-attachments": return .mailAttachments
        case "trash-bins": return .trashBins
        case "dev-tools", "package-managers", "docker": return .devTools
        case "network": return .networkCleanup
        case "privacy", "browser-chrome", "browser-safari", "browser-firefox", "browser-brave", "browser-arc", "service-workers":
            return .privacy
        case "large-files": return .largeOldFiles
        case "duplicates": return .duplicateFiles
        case "similar-photos": return .similarPhotos
        case "cloud-cleanup": return .cloudCleanup
        default: return nil
        }
    }

    func runAssistantPlan(_ plan: AssistantScanPlan) async {
        await startScan(scope: ScanScope(
            modules: plan.modules,
            assistantTargets: plan.customTargets
        ))
    }

    private func applyScanResults(_ items: [CleanupItem], modules: [String]?) {
        scanResults = items.sorted { $0.size > $1.size }

        let summary = SmartCareAnalyzer().summarize(items: scanResults, diskUsage: diskUsage)
        smartCareSummary = summary

        if modules == nil || Set(modules ?? []).isSuperset(of: SmartCareDefaults.moduleIDs) {
            selectedItems = summary.recommendedCleanupItemIDs
        } else {
            selectedItems = Set(scanResults.map(\.id))
        }
    }

    private func startScan(scope: ScanScope) async {
        // Serialize concurrent scan requests instead of dropping them. The previous
        // early `return` discarded this caller's modules/targets and let them see an
        // unrelated in-flight scan's results (e.g. an assistant plan showing a
        // background quick-scan's findings). Wait for any in-flight scan — and any a
        // peer waiter starts ahead of us — to finish, THEN run the requested scan.
        while let activeScanTask {
            await activeScanTask.value
        }

        let scanID = UUID()
        activeScanID = scanID

        let task = Task { @MainActor in
            await self.performScan(
                scope: scope
            )

            if self.activeScanID == scanID {
                self.activeScanTask = nil
                self.activeScanID = nil
            }
        }

        activeScanTask = task
        await task.value
    }

    private func performScan(scope: ScanScope) async {
        lastScanScope = scope
        isScanning = true
        scanProgress = 0
        currentScanModule = "Preparing scan"
        scanResults = []
        selectedItems = []
        smartCareSummary = nil
        scanFailures = []
        lastError = nil

        defer {
            isScanning = false
            currentScanModule = nil
        }

        let progressHandler: ScanProgressHandler = { update in
            await MainActor.run {
                self.scanProgress = update.fractionCompleted

                if let moduleName = update.moduleName {
                    self.currentScanModule = "Completed \(moduleName)"
                } else if update.totalModules > 0 {
                    self.currentScanModule = "Scanning \(update.totalModules) modules"
                } else {
                    self.currentScanModule = "Preparing scan"
                }
            }
        }

        do {
            async let primaryResult = scanEngine.scanWithDiagnostics(
                modules: scope.modules,
                progress: progressHandler
            )
            async let watchlistItems = scanEngine.scanAssistantTargets(scope.assistantTargets)
            let result = await primaryResult
            currentScanModule = scope.assistantTargets.isEmpty
                ? "Finalizing results"
                : "Checking assistant watchlist"
            scanProgress = max(scanProgress, 0.95)
            let persistentItems = try await watchlistItems
            let combined = deduplicated(items: result.items + persistentItems)
            scanFailures = result.failures.sorted {
                $0.moduleName.localizedStandardCompare($1.moduleName) == .orderedAscending
            }
            applyScanResults(combined, modules: scope.modules)
            scanProgress = 1
        } catch is CancellationError {
            // User-initiated stop — not an error worth a banner.
        } catch {
            // Surface to the UI instead of swallowing into a console log.
            lastError = "Scan failed: \(error.localizedDescription)"
        }
    }

    private func deduplicated(items: [CleanupItem]) -> [CleanupItem] {
        var seen = Set<String>()
        return items.filter { item in
            let key = "\(item.module)|\(item.path.path)"
            return seen.insert(key).inserted
        }
    }
}

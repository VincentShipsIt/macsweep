import SwiftUI
import AppKit

/// Main dashboard view in the native, list-driven house style used by Inbox.
struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var monitor = SystemMonitor()
    @State private var expandedWidget: WidgetType? = nil
    @State private var isCleanupReviewExpanded = false
    @State private var showFDABanner = true
    @State private var showingConfirmation = false
    @State private var recommendedItemsToClean: Set<CleanupItem.ID> = []

    var body: some View {
        VStack(spacing: 0) {
            if !appState.hasFullDiskAccess && showFDABanner {
                fdaBanner
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
            }

            List {
                Section("Smart Care") {
                    smartCareHeaderRow

                    if appState.isScanning {
                        ScanProgressStatusView(
                            progress: appState.scanProgress,
                            message: appState.currentScanModule ?? "Scanning",
                            compact: true
                        )
                        .padding(.vertical, 4)
                        .dashboardConditionalRow()
                    }

                    if let lastError = appState.lastError {
                        StatusMessageRow(
                            icon: "exclamationmark.triangle",
                            tint: .orange,
                            title: "Scan Failed",
                            detail: lastError
                        )
                        .dashboardConditionalRow()
                    }

                    if !appState.scanFailures.isEmpty {
                        PartialScanStatusRow(
                            failures: appState.scanFailures,
                            isRetryDisabled: !appState.hasFullDiskAccess,
                            retry: {
                                Task { await appState.retryLastScan() }
                            },
                            openFullDiskAccess: FullDiskAccess.openSystemPreferences,
                            copyDetails: copyPartialScanDetails
                        )
                        .dashboardConditionalRow()
                    }

                    if let deletionError = appState.lastDeletionError {
                        StatusMessageRow(
                            icon: "exclamationmark.triangle",
                            tint: .red,
                            title: "Cleanup Failed",
                            detail: deletionError
                        )
                        .dashboardConditionalRow()
                    }

                    if let summary = appState.smartCareSummary,
                       summary.findings.isEmpty,
                       !appState.isScanning,
                       appState.lastError == nil {
                        StatusMessageRow(
                            icon: "checkmark.circle",
                            tint: .green,
                            title: "No cleanup needed",
                            detail: "Smart Care found no items to recommend or review."
                        )
                        .dashboardConditionalRow()
                    }

                    cleanupReviewRows
                        .disabled(!appState.hasFullDiskAccess)
                }

                if let summary = appState.smartCareSummary, !summary.recommendedFindings.isEmpty {
                    Section("Recommended") {
                        SmartCareGroupSummaryRow(
                            icon: "checkmark.shield",
                            tint: .green,
                            title: "Safe cleanup",
                            detail: "Generated files and caches that Smart Care can clean safely are preselected."
                        )

                        ForEach(summary.recommendedFindings) { finding in
                            smartCareFindingRow(finding)
                        }
                    }
                }

                if let summary = appState.smartCareSummary, !summary.reviewRequiredFindings.isEmpty {
                    Section("Needs Review") {
                        SmartCareGroupSummaryRow(
                            icon: "doc.text.magnifyingglass",
                            tint: .orange,
                            title: "Your decision",
                            detail: "Smart Care never includes personal files or look-alike matches in recommended cleanup. "
                                + "Open a category to review them."
                        )

                        ForEach(summary.reviewRequiredFindings) { finding in
                            smartCareFindingRow(finding)
                        }
                    }
                }

                Section("Recommendations") {
                    recommendationRows
                }

                Section("Mac Overview") {
                    overviewRows
                }

                if appState.lastCleanup != nil || !appState.scanResults.isEmpty {
                    Section("Recent Activity") {
                        recentActivityRows
                    }
                }
            }
            .listStyle(.inset)
            .macSweepListSurface()
            // Drive appearance/disappearance of the conditional status rows and
            // whole sections above through a single animation transaction. Custom
            // `.transition`s on `List` children are otherwise overridden by the
            // List's own default row animation and pop in unanimated; keying the
            // transaction to a visibility snapshot animates rows and sections
            // consistently while leaving continuous updates (scan progress, live
            // metrics) unanimated.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: sectionVisibility)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.clear)
        .navigationTitle("")
        .navigationSubtitle("")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                rescanButton
                cleanRecommendedButton
            }
        }
        .onChange(of: appState.isScanning) { _, isScanning in
            if !isScanning && !appState.scanResults.isEmpty {
                // Match the user-driven collapse (see `cleanupReviewRows`) so the
                // programmatic reset animates identically instead of snapping.
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    isCleanupReviewExpanded = false
                }
            }
        }
        .onChange(of: appState.hasFullDiskAccess) {
            guard !appState.hasFullDiskAccess else { return }
            showingConfirmation = false
        }
        .cleanupReview(
            isPresented: $showingConfirmation,
            items: recommendedCleanupItems,
            disposition: .mixed,
            note: "Recommended items remain separated from review-only personal files. "
                + "Every path is checked again immediately before its module runs.",
            onConfirm: { await cleanRecommended() }
        )
        .onChange(of: showingConfirmation) { _, isPresented in
            if !isPresented {
                recommendedItemsToClean = []
            }
        }
    }

    private func cleanRecommended() async -> CleanupResult? {
        guard appState.hasFullDiskAccess else {
            appState.lastDeletionError = FullDiskAccessScope.smartCare.actionBlockedMessage
            return nil
        }

        // Apply the reviewed recommended set to the shared selection only
        // on confirm — Cancel must never clobber a curated selection.
        appState.selectedItems = recommendedItemsToClean
        return try? await appState.deleteSelected(confirmedLargeDeletion: true)
    }

    /// Snapshot of which conditional status rows/sections are currently visible.
    /// Feeding it to `.animation(_:value:)` on the List opens an animation
    /// transaction only when a row/section actually appears or disappears — never
    /// for continuous updates like scan progress or live metric readouts.
    private var sectionVisibility: DashboardSectionVisibility {
        let summary = appState.smartCareSummary
        return DashboardSectionVisibility(
            isScanning: appState.isScanning,
            hasError: appState.lastError != nil,
            hasFailures: !appState.scanFailures.isEmpty,
            hasDeletionError: appState.lastDeletionError != nil,
            showsEmptySummary: summary?.findings.isEmpty == true
                && !appState.isScanning
                && appState.lastError == nil,
            hasRecommended: !(summary?.recommendedFindings.isEmpty ?? true),
            hasNeedsReview: !(summary?.reviewRequiredFindings.isEmpty ?? true),
            hasRecentActivity: appState.lastCleanup != nil || !appState.scanResults.isEmpty
        )
    }

    private var rescanButton: some View {
        Button {
            Task {
                await appState.quickScan()
            }
        } label: {
            Image(systemName: appState.isScanning ? "hourglass" : "arrow.clockwise")
        }
        .disabled(appState.isScanning || !appState.hasFullDiskAccess)
        .help(scanButtonTitle)
    }

    private var cleanRecommendedButton: some View {
        Button {
            confirmRecommendedCleanup()
        } label: {
            Image(systemName: "trash")
        }
        .disabled(!hasRecommendedCleanup || appState.isScanning || !appState.hasFullDiskAccess)
        .help("Clean Recommended")
    }

    // MARK: - FDA Banner

    private var fdaBanner: some View {
        FullDiskAccessWarningBanner(scope: .smartCare) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                showFDABanner = false
            }
        }
    }

    // MARK: - Smart Care

    private var smartCareHeaderRow: some View {
        HStack(alignment: .center, spacing: 12) {
            DashboardRowIcon(systemName: "sparkles.rectangle.stack", tint: smartCareScoreColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(smartCareHeadline)
                    .font(.headline)

                Text(smartCareDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(appState.smartCareSummary?.score ?? 100)")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .monospacedDigit()

                Text(appState.scanFailures.isEmpty ? "Score" : "Partial Score")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let summary = appState.smartCareSummary {
                    Text(summary.formattedBytes)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !appState.scanFailures.isEmpty {
                        Text("from partial results")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    // Routed through the shared MetricThresholds so the dashboard score and the
    // menu-bar companion can never disagree on what counts as "healthy".
    private var smartCareScoreColor: Color {
        MetricThresholds.score(appState.smartCareSummary?.score ?? 100).color
    }

    private var scanButtonTitle: String {
        appState.smartCareSummary == nil ? "Run Smart Care" : "Rescan"
    }

    private var smartCareHeadline: String {
        if appState.isScanning {
            return "Scan in progress"
        }
        if let summary = appState.smartCareSummary {
            return summary.score >= 85 ? "Your Mac is in good shape" : "Cleanup opportunities found"
        }
        return "Inspect high-impact cleanup categories"
    }

    private var smartCareDescription: String {
        if appState.isScanning {
            return appState.currentScanModule ?? "MacSweep is scanning in the background."
        }
        if let summary = appState.smartCareSummary {
            let prefix = appState.scanFailures.isEmpty ? "" : "Partial results: "
            return "\(prefix)\(summary.issueCount) items across \(summary.findings.count) categories. "
                + "Recommended safe items are preselected."
        }
        return "Scans junk, large files, duplicates, similar photos, developer artifacts, and cloud storage waste."
    }

    private func copyPartialScanDetails() {
        let lines = appState.scanFailures.map {
            "\($0.moduleName) [\($0.moduleID)]: \($0.message)"
        }
        let report = (["macsweep.dev partial scan report"] + lines).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    private var hasRecommendedCleanup: Bool {
        !(appState.smartCareSummary?.recommendedCleanupItemIDs.isEmpty ?? true)
    }

    private func confirmRecommendedCleanup() {
        recommendedItemsToClean = appState.smartCareSummary?.recommendedCleanupItemIDs ?? []
        showingConfirmation = true
    }

    private func smartCareFindingRow(_ finding: SmartCareFinding) -> some View {
        SmartCareFindingRow(finding: finding) {
            if let feature = appState.feature(for: finding.moduleID) {
                appState.selectedFeature = feature
            }
        }
    }

    @ViewBuilder
    private var cleanupReviewRows: some View {
        if !appState.scanResults.isEmpty {
            CleanupReviewSummaryRow(
                isExpanded: isCleanupReviewExpanded,
                selectedCount: selectedCleanupItems.count,
                totalCount: appState.scanResults.count,
                selectedSizeText: selectedCleanupSizeText
            ) {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    isCleanupReviewExpanded.toggle()
                }
            }

            if isCleanupReviewExpanded {
                CleanupReviewBulkActionsRow(
                    selectedCount: selectedCleanupItems.count,
                    totalCount: appState.scanResults.count,
                    selectedSizeText: selectedCleanupSizeText,
                    hasRecommendedItems: !(appState.smartCareSummary?.recommendedCleanupItemIDs.isEmpty ?? true),
                    selectRecommended: appState.selectRecommended,
                    selectAll: appState.selectAll,
                    selectNone: appState.deselectAll
                )

                ForEach(cleanupReviewGroups) { group in
                    CleanupReviewGroupHeader(
                        group: group,
                        toggleSelection: {
                            if group.isFullySelected {
                                appState.deselectItems(withIDs: group.itemIDs)
                            } else {
                                appState.selectItems(withIDs: group.itemIDs)
                            }
                        }
                    )

                    ForEach(group.items) { item in
                        CleanupReviewItemRow(
                            item: item,
                            isSelected: appState.selectedItems.contains(item.id)
                        ) {
                            appState.toggleSelection(for: item)
                        }
                    }
                }
            }
        }
    }

    private var selectedCleanupItems: [CleanupItem] {
        appState.scanResults.filter { appState.selectedItems.contains($0.id) }
    }

    private var recommendedCleanupItems: [CleanupItem] {
        appState.scanResults.filter { recommendedItemsToClean.contains($0.id) }
    }

    private var selectedCleanupSizeText: String {
        selectedCleanupItems.formattedTotalSize()
    }

    private var cleanupReviewGroups: [CleanupReviewGroup] {
        Dictionary(grouping: appState.scanResults, by: \.module)
            .map { moduleID, items in
                let sortedItems = items.sorted { lhs, rhs in
                    if lhs.size == rhs.size {
                        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                    }
                    return lhs.size > rhs.size
                }
                let selectedItems = sortedItems.filter { appState.selectedItems.contains($0.id) }

                return CleanupReviewGroup(
                    id: moduleID,
                    title: sortedItems.first?.moduleName ?? moduleID.replacingOccurrences(of: "-", with: " ").capitalized,
                    items: sortedItems,
                    selectedCount: selectedItems.count,
                    selectedBytes: selectedItems.reduce(0) { $0 + $1.size },
                    totalBytes: sortedItems.reduce(0) { $0 + $1.size }
                )
            }
            .sorted { lhs, rhs in
                if lhs.totalBytes == rhs.totalBytes {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return lhs.totalBytes > rhs.totalBytes
            }
    }

    // MARK: - Recommendations

    @ViewBuilder
    private var recommendationRows: some View {
        RecommendationRow(
            icon: "magnifyingglass",
            title: "Run Deep Scan",
            detail: "Find junk files, caches, and large files.",
            buttonTitle: "Scan",
            isLoading: appState.isScanning,
            isDisabled: !appState.hasFullDiskAccess
        ) {
            Task {
                await appState.scan()
            }
        }

        if hasSmartCareFinding(for: "large-files") {
            RecommendationRow(
                icon: "doc.badge.clock",
                title: "Large & Old Files",
                detail: "Find files taking up space.",
                buttonTitle: "Open"
            ) {
                appState.selectedFeature = .largeOldFiles
            }
        }

        if hasSmartCareFinding(for: "dev-tools") {
            RecommendationRow(
                icon: "hammer",
                title: "Developer Tools",
                detail: "Clean node_modules, DerivedData, package caches, and stale build artifacts.",
                buttonTitle: "Open"
            ) {
                appState.selectedFeature = .devTools
            }
        }

        if hasSmartCareFinding(for: "duplicates") {
            RecommendationRow(
                icon: "doc.on.doc",
                title: "Duplicate Files",
                detail: "Find redundant copies and recover wasted storage.",
                buttonTitle: "Open"
            ) {
                appState.selectedFeature = .duplicateFiles
            }
        }

        if monitor.batteryInfo.hasBattery {
            RecommendationRow(
                icon: monitor.batteryInfo.icon,
                title: "Battery Monitor",
                detail: "Track health, cycle count, and charge behavior.",
                buttonTitle: "Open"
            ) {
                appState.selectedFeature = .batteryMonitor
            }
        }

        if hasSmartCareFinding(for: "similar-photos") {
            RecommendationRow(
                icon: "photo.stack",
                title: "Similar Photos",
                detail: "Review visually similar images and keep the best shots.",
                buttonTitle: "Open"
            ) {
                appState.selectedFeature = .similarPhotos
            }
        }

        if hasSmartCareFinding(for: "cloud-cleanup") {
            RecommendationRow(
                icon: "icloud",
                title: "Cloud Cleanup",
                detail: "Reclaim local storage from stale cloud copies and caches.",
                buttonTitle: "Open"
            ) {
                appState.selectedFeature = .cloudCleanup
            }
        }
    }

    private func hasSmartCareFinding(for moduleID: String) -> Bool {
        appState.smartCareSummary?.findings.contains { $0.moduleID == moduleID } ?? false
    }

    // MARK: - Mac Overview

    @ViewBuilder
    private var overviewRows: some View {
        Button {
            toggleWidget(.storage)
        } label: {
            SystemStatusRow(
                icon: "internaldrive",
                tint: storageColor,
                title: "Macintosh HD",
                detail: "Available: \(monitor.diskUsage?.formattedFree ?? "...")",
                progress: 1.0 - (monitor.diskUsage?.freePercentage ?? 0.5),
                progressTint: storageColor,
                alertLevel: storageAlertLevel
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: binding(for: .storage), arrowEdge: .trailing) {
            StorageDetailView(monitor: monitor)
                .environmentObject(appState)
                .dashboardPopoverContent()
        }

        Button {
            toggleWidget(.memory)
        } label: {
            SystemStatusRow(
                icon: "memorychip",
                tint: memoryColor,
                title: "Memory",
                detail: "Available: \(monitor.memoryUsage.formattedAvailable)",
                progress: monitor.memoryUsage.usedPercentage,
                progressTint: memoryColor,
                alertLevel: memoryAlertLevel
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: binding(for: .memory), arrowEdge: .trailing) {
            MemoryDetailView(monitor: monitor, processMonitor: appState.processMonitor)
                .dashboardPopoverContent()
        }

        Button {
            toggleWidget(.battery)
        } label: {
            SystemStatusRow(
                icon: monitor.batteryInfo.icon,
                tint: batteryColor,
                title: "Battery",
                detail: monitor.batteryInfo.statusText,
                value: batteryValueText,
                alertLevel: batteryAlertLevel
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: binding(for: .battery), arrowEdge: .trailing) {
            BatteryDetailView(monitor: monitor)
                .dashboardPopoverContent()
        }

        Button {
            toggleWidget(.cpu)
        } label: {
            SystemStatusRow(
                icon: "cpu",
                tint: cpuColor,
                title: "CPU",
                detail: monitor.cpuUsage.formattedLoad,
                value: monitor.cpuUsage.formattedTemperature,
                valueTint: cpuTempColor,
                alertLevel: cpuAlertLevel
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: binding(for: .cpu), arrowEdge: .trailing) {
            CPUDetailView(monitor: monitor, processMonitor: appState.processMonitor)
                .dashboardPopoverContent()
        }

        Button {
            toggleWidget(.network)
        } label: {
            SystemStatusRow(
                icon: "wifi",
                tint: .green,
                title: monitor.networkUsage.ssid ?? "Wi-Fi",
                detail: "Down \(monitor.networkUsage.formattedDownload)  Up \(monitor.networkUsage.formattedUpload)"
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: binding(for: .network), arrowEdge: .trailing) {
            NetworkDetailView(monitor: monitor)
                .dashboardPopoverContent()
        }

        Button {
            toggleWidget(.devices)
        } label: {
            SystemStatusRow(
                icon: "antenna.radiowaves.left.and.right",
                tint: devicesColor,
                title: "Connected Devices",
                detail: connectedDevicesSubtitle,
                value: lowestDeviceBattery.map { "\($0)%" },
                valueTint: devicesColor,
                alertLevel: devicesAlertLevel
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: binding(for: .devices), arrowEdge: .trailing) {
            ConnectedDevicesDetailView(monitor: monitor)
                .dashboardScrollablePopoverContent()
        }

        Button {
            toggleWidget(.system)
        } label: {
            SystemStatusRow(
                icon: "desktopcomputer",
                tint: .secondary,
                title: Host.current().localizedName ?? "Mac",
                detail: systemVersion
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: binding(for: .system), arrowEdge: .trailing) {
            SystemDetailView(monitor: monitor)
                .dashboardPopoverContent()
        }
    }

    private func toggleWidget(_ widget: WidgetType) {
        // `expandedWidget` only feeds the `.popover(isPresented:)` bindings below,
        // and NSPopover animates its own present/dismiss — the previous
        // `withAnimation` wrapper animated nothing, so it's dropped.
        expandedWidget = expandedWidget == widget ? nil : widget
    }

    private func binding(for widget: WidgetType) -> Binding<Bool> {
        Binding(
            get: { expandedWidget == widget },
            set: { if !$0 { expandedWidget = nil } }
        )
    }

    // MARK: - Recent Activity

    @ViewBuilder
    private var recentActivityRows: some View {
        if let cleanup = appState.lastCleanup {
            StatusMessageRow(
                icon: "checkmark.circle",
                tint: .green,
                title: "Last Cleanup",
                detail: "Freed \(cleanup.formattedBytesFreed) \(relativeTimeText(for: cleanup.timestamp))"
            )

            HStack(spacing: 12) {
                DashboardRowIcon(systemName: "square.and.arrow.up", tint: .purple)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Share your results")
                        .font(.headline)
                    Text("Create a social cleanup card from your cleanup history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Share") {
                    appState.selectedFeature = .share
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        }

        if !appState.scanResults.isEmpty {
            HStack(spacing: 12) {
                DashboardRowIcon(systemName: "doc.badge.clock", tint: .orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan Results")
                        .font(.headline)
                    Text("\(appState.scanResults.count) items • \(scanResultsSizeText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Review") {
                    appState.selectedFeature = .systemJunk
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Helpers

    private var scanResultsSizeText: String {
        appState.scanResults.formattedTotalSize()
    }

    private var systemVersion: String {
        let version = Foundation.ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private func relativeTimeText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Alert Levels

    private var storageAlertLevel: MetricAlertLevel {
        guard let usage = monitor.diskUsage else { return .normal }
        return MetricThresholds.storage(freePercent: usage.freePercentage)
    }

    private var memoryAlertLevel: MetricAlertLevel {
        MetricThresholds.memory(usagePercent: monitor.memoryUsage.usedPercentage)
    }

    private var batteryAlertLevel: MetricAlertLevel {
        MetricThresholds.battery(
            percent: monitor.batteryInfo.percentage,
            isCharging: monitor.batteryInfo.isCharging,
            hasBattery: monitor.batteryInfo.hasBattery
        )
    }

    private var cpuAlertLevel: MetricAlertLevel {
        MetricThresholds.cpu(usage: monitor.cpuUsage.total, temperature: monitor.cpuUsage.temperature)
    }

    // MARK: - Colors

    private var storageColor: Color {
        storageAlertLevel.color
    }

    private var memoryColor: Color {
        memoryAlertLevel.color
    }

    private var batteryColor: Color {
        if !monitor.batteryInfo.hasBattery {
            return .green
        }
        return batteryAlertLevel.color
    }

    private var batteryValueText: String {
        monitor.batteryInfo.hasBattery ? "\(monitor.batteryInfo.percentage)%" : "AC"
    }

    private var cpuColor: Color {
        cpuAlertLevel.color
    }

    private var cpuTempColor: Color {
        guard monitor.cpuUsage.temperature != nil else { return .primary }
        return MetricThresholds.cpuTemperature(monitor.cpuUsage.temperature).color
    }

    // MARK: - Connected Devices (merged from the connected-devices feature)

    private var connectedDevicesSubtitle: String {
        ConnectedDevicesSummary.subtitle(for: monitor.connectedDevices)
    }

    private var lowestDeviceBattery: Int? {
        monitor.connectedDevices.compactMap(\.lowestBattery).min()
    }

    private var devicesAlertLevel: MetricAlertLevel {
        guard let lowest = lowestDeviceBattery else { return .normal }
        if lowest <= 10 { return .critical }
        if lowest <= 20 { return .warning }
        return .normal
    }

    private var devicesColor: Color {
        switch devicesAlertLevel {
        case .normal: return .cyan
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

struct PartialScanStatusRow: View {
    let failures: [ModuleScanFailure]
    let isRetryDisabled: Bool
    let retry: () -> Void
    let openFullDiskAccess: () -> Void
    let copyDetails: () -> Void

    private var hasPermissionFailure: Bool {
        failures.contains(where: \.requiresFullDiskAccess)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Partial results")
                    .font(.headline)
                Text("\(failures.count) \(failures.count == 1 ? "module" : "modules") could not be scanned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(failures, id: \.moduleID) { failure in
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.moduleName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(failure.conciseMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 8) {
                if hasPermissionFailure {
                    Button("Open Full Disk Access", action: openFullDiskAccess)
                }
                Button("Retry", action: retry)
                    .disabled(isRetryDisabled)
                Button("Copy Details", action: copyDetails)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}

enum DashboardPopoverLayout {
    static let width: CGFloat = 380
    static let maxScrollableHeight: CGFloat = 620
}

/// Equatable snapshot of the dashboard's conditional row/section visibility,
/// keyed by `.animation(_:value:)` so appearances/disappearances animate as one
/// transaction. Deliberately holds only booleans — no continuously-changing
/// values — so live scan progress and metric updates don't trigger it.
struct DashboardSectionVisibility: Equatable {
    let isScanning: Bool
    let hasError: Bool
    let hasFailures: Bool
    let hasDeletionError: Bool
    let showsEmptySummary: Bool
    let hasRecommended: Bool
    let hasNeedsReview: Bool
    let hasRecentActivity: Bool
}

extension View {
    /// Shared appearance transition for the dashboard's conditional status rows so
    /// they fade and slide in from the top consistently instead of popping. The
    /// enclosing List-level `.animation(_:value:)` supplies the transaction that
    /// drives it (and the reduce-motion guard).
    func dashboardConditionalRow() -> some View {
        transition(.opacity.combined(with: .move(edge: .top)))
    }

    func dashboardPopoverContent() -> some View {
        frame(width: DashboardPopoverLayout.width)
            .fixedSize(horizontal: false, vertical: true)
    }

    func dashboardScrollablePopoverContent(maxHeight: CGFloat = DashboardPopoverLayout.maxScrollableHeight) -> some View {
        ScrollView {
            self
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .frame(width: DashboardPopoverLayout.width)
        .frame(maxHeight: maxHeight)
    }
}

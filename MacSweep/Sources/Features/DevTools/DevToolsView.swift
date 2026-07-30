import AppKit
import SwiftUI

@MainActor
private final class DevToolsScanSession: ObservableObject {
    static let shared = DevToolsScanSession()

    @Published var hasCompletedBuildArtifactScan = false
    @Published var isBuildArtifactScanRunning = false
    @Published var buildArtifactScanState = BuildArtifactScanState()

    private init() {}
}

/// View for cleaning up developer artifacts
struct DevToolsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var scanSession = DevToolsScanSession.shared
    @State private var selectedTab: DevToolsTab = .artifacts

    enum DevToolsTab: String, CaseIterable {
        case artifacts = "Build Artifacts"
        case packages = "Package Managers"
    }

    private var showsBuildArtifactLanding: Bool {
        selectedTab == .artifacts
            && (!scanSession.hasCompletedBuildArtifactScan || scanSession.isBuildArtifactScanRunning)
    }

    var body: some View {
        FeaturePageShell(
            title: "Developer Tools",
            subtitle: "Clean build artifacts, caches, and stale Git branches.",
            hidesChrome: showsBuildArtifactLanding,
            scrolls: showsBuildArtifactLanding
        ) {
            VStack(spacing: 0) {
                Picker("Developer tool category", selection: $selectedTab) {
                    ForEach(DevToolsTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .padding(12)

                Divider()

                switch selectedTab {
                case .artifacts:
                    BuildArtifactsView(
                        scanState: $scanSession.buildArtifactScanState,
                        hasCompletedScan: $scanSession.hasCompletedBuildArtifactScan,
                        isScanRunning: $scanSession.isBuildArtifactScanRunning
                    )
                case .packages:
                    PackageManagersView()
                }
            }
        }
    }
}

/// View for cleaning up build artifacts (node_modules, DerivedData, etc.)
struct BuildArtifactsView: View {
    @EnvironmentObject var appState: AppState
    @Binding private var scanState: BuildArtifactScanState
    @Binding private var hasCompletedScan: Bool
    @Binding private var isScanRunning: Bool
    @State private var showingConfirmation = false
    @State private var viewMode: ViewMode = .projects
    @State private var filterType: ProjectType? = nil

    enum ViewMode: String, CaseIterable {
        case projects = "By Project"
        case type = "By Type"
        case all = "All Items"
    }

    init(
        scanState: Binding<BuildArtifactScanState>,
        hasCompletedScan: Binding<Bool> = .constant(false),
        isScanRunning: Binding<Bool> = .constant(false)
    ) {
        self._scanState = scanState
        self._hasCompletedScan = hasCompletedScan
        self._isScanRunning = isScanRunning
    }

    private var projects: [ProjectInfo] {
        get { scanState.projects }
        nonmutating set { scanState.projects = newValue }
    }

    private var isScanning: Bool {
        get { scanState.isScanning }
        nonmutating set { scanState.isScanning = newValue }
    }

    private var projectCleanupItems: [CleanupItem] {
        get { scanState.projectCleanupItems }
        nonmutating set { scanState.projectCleanupItems = newValue }
    }

    private var systemArtifacts: [CleanupItem] {
        get { scanState.systemArtifacts }
        nonmutating set { scanState.systemArtifacts = newValue }
    }

    private var gitArtifacts: [GitCleanupItem] {
        get { scanState.gitArtifacts }
        nonmutating set { scanState.gitArtifacts = newValue }
    }

    private var selectedItems: Set<UUID> {
        get { scanState.selectedItems }
        nonmutating set { scanState.selectedItems = newValue }
    }

    private var selectedGitItems: Set<UUID> {
        get { scanState.selectedGitItems }
        nonmutating set { scanState.selectedGitItems = newValue }
    }

    private var gitToolStatus: GitToolStatus? {
        get { scanState.gitToolStatus }
        nonmutating set { scanState.gitToolStatus = newValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Inline banner is the default non-blocking error surface; a failed
            // cleanup leaves the page usable, so it stays inline rather than modal.
            if let errorMessage = scanState.errorMessage {
                MacSweepErrorBanner(message: errorMessage) {
                    scanState.errorMessage = nil
                }
            }

            artifactContent
        }
    }

    @ViewBuilder
    private var artifactContent: some View {
        Group {
            if isScanning {
                ScanLandingView(
                    icon: "hammer",
                    title: "Find Developer Artifacts",
                    description: "Scan for node_modules, DerivedData, stale worktrees, and merged branches.",
                    ctaTitle: "Scan Developer Tools",
                    benefits: [
                        ScanBenefit("internaldrive", "Reclaims gigabytes of build junk", "Sweeps node_modules, DerivedData, and build caches that quietly pile up across every project on your Mac."),
                        ScanBenefit("arrow.triangle.branch", "Tidies stale Git clutter", "Spots merged branches and abandoned worktrees, while flagging projects in active development so nothing live gets touched."),
                    ],
                    illustration: "hammer",
                    isScanning: true,
                    action: { Task { await scan() } }
                )
                .transition(.scanCrossfade)
            } else if !hasCompletedScan {
                ScanLandingView(
                    icon: "hammer",
                    title: "Find Developer Artifacts",
                    description: "Scan for node_modules, DerivedData, stale worktrees, and merged branches.",
                    ctaTitle: "Scan Developer Tools",
                    benefits: [
                        ScanBenefit("internaldrive", "Reclaims gigabytes of build junk", "Sweeps node_modules, DerivedData, and build caches that quietly pile up across every project on your Mac."),
                        ScanBenefit("arrow.triangle.branch", "Tidies stale Git clutter", "Spots merged branches and abandoned worktrees, while flagging projects in active development so nothing live gets touched."),
                    ],
                    illustration: "hammer",
                    action: { Task { await scan() } }
                )
                .transition(.scanCrossfade)
            } else if projects.isEmpty && systemArtifacts.isEmpty && gitArtifacts.isEmpty {
                noArtifactsView
                    .transition(.scanCrossfade)
            } else {
                VStack(spacing: 0) {
                    toolbar
                    Divider()

                    contentView

                    Divider()
                    footer
                }
                .transition(.scanCrossfade)
            }
        }
        // Crossfade every scan-stage swap (scanning ⇄ landing ⇄ empty ⇄ results);
        // no-ops under Reduce Motion.
        .animated(.scanCrossfade, value: scanPhase)
    }

    /// Which scan stage is on screen, so the crossfade fires on *every* arm
    /// change. DevTools models its in-progress state as a distinct arm (rather
    /// than `ScanLandingView`'s internal `isScanning`), so `.scanning` is its own
    /// phase here.
    private var scanPhase: ScanPhase {
        if isScanning { return .scanning }
        if !hasCompletedScan { return .landing }
        if projects.isEmpty && systemArtifacts.isEmpty && gitArtifacts.isEmpty { return .empty }
        return .results
    }

    private var noArtifactsView: some View {
        EmptyResultState(
            icon: "checkmark.circle",
            title: "No Developer Artifacts Found",
            message: "No build artifacts, stale worktrees, or merged branches were found.",
            actionTitle: "Scan Again",
            action: { Task { await scan() } }
        )
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(spacing: 12) {
            HStack {
                // View mode picker
                Picker("View", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 280)

                Spacer()

                RescanButton(isScanning: isScanning) { Task { await scan() } }
            }

            // Project type filter
            if viewMode == .projects && !projects.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    // Adjacent glass pills share one container so they sample the
                    // same region and read as a cohesive cluster; the container
                    // spacing matches the HStack spacing.
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            FilterChip(label: "All", isSelected: filterType == nil) {
                                filterType = nil
                            }

                            ForEach(availableTypes, id: \.self) { type in
                                FilterChip(label: type.rawValue, isSelected: filterType == type) {
                                    filterType = type
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }

            if let gitToolStatus {
                HStack(spacing: 8) {
                    Label(
                        gitToolStatus.canUseGitHubCLI ? "GitHub CLI connected" : (gitToolStatus.ghPath == nil ? "GitHub CLI unavailable" : "GitHub CLI installed"),
                        systemImage: gitToolStatus.canUseGitHubCLI ? "checkmark.circle.fill" : "terminal"
                    )
                    .font(.caption2)
                    .foregroundStyle(gitToolStatus.canUseGitHubCLI ? .green : .secondary)

                    Text(gitToolStatus.canUseGitHubCLI ? "PR state can help identify merged or closed stale branches." : "Local Git checks still protect branch and worktree cleanup.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Spacer()
                }
            }
        }
        .padding()
    }

    // MARK: - Content View

    @ViewBuilder
    private var contentView: some View {
        switch viewMode {
        case .projects:
            projectsView
        case .type:
            byTypeView
        case .all:
            allItemsView
        }
    }

    private var projectsView: some View {
        List(selection: $scanState.selectedItems) {
            // Projects section
            if !filteredProjects.isEmpty {
                Section("Projects (\(filteredProjects.count))") {
                    ForEach(filteredProjects) { project in
                        ProjectRow(
                            project: project,
                            isSelected: cleanupItemIDs(for: project).allSatisfy { selectedItems.contains($0) },
                            onToggle: {
                                toggleProject(project)
                            }
                        )
                    }
                }
            }

            // System artifacts section
            if !systemArtifacts.isEmpty {
                Section("System Artifacts") {
                    ForEach(systemArtifacts) { item in
                        ArtifactRow(item: item, isSelected: selectedItems.contains(item.id))
                            .tag(item.id)
                    }
                }
            }

            if !gitArtifacts.isEmpty {
                Section("Stale Git Worktrees & Branches") {
                    ForEach(gitArtifacts) { item in
                        GitArtifactRow(
                            item: item,
                            isSelected: selectedGitItems.contains(item.id),
                            onToggle: {
                                toggleGitItem(item)
                            }
                        )
                    }
                }
            }
        }
        .listStyle(.inset)
        .macSweepListSurface()
    }

    private var byTypeView: some View {
        List(selection: $scanState.selectedItems) {
            ForEach(ProjectType.allCases, id: \.self) { type in
                let typeProjects = projects.filter { $0.type == type }
                if !typeProjects.isEmpty {
                    Section {
                        ForEach(typeProjects) { project in
                            ProjectRow(
                                project: project,
                                isSelected: cleanupItemIDs(for: project).allSatisfy { selectedItems.contains($0) },
                                onToggle: { toggleProject(project) }
                            )
                        }
                    } header: {
                        HStack {
                            Image(systemName: type.icon)
                            Text(type.rawValue)
                            Spacer()
                            Text("\(typeProjects.count) projects • \(totalSizeForType(type))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .macSweepListSurface()
    }

    private var allItemsView: some View {
        List(selection: $scanState.selectedItems) {
            if !allCleanupItems.isEmpty {
                Section("Build Artifacts") {
                    ForEach(allCleanupItems) { item in
                        ArtifactRow(item: item, isSelected: selectedItems.contains(item.id))
                            .tag(item.id)
                    }
                }
            }

            if !gitArtifacts.isEmpty {
                Section("Stale Git Worktrees & Branches") {
                    ForEach(gitArtifacts) { item in
                        GitArtifactRow(
                            item: item,
                            isSelected: selectedGitItems.contains(item.id),
                            onToggle: {
                                toggleGitItem(item)
                            }
                        )
                    }
                }
            }
        }
        .listStyle(.inset)
        .macSweepListSurface()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(selectedCount) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if recentlyModifiedCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                            Text("\(recentlyModifiedCount) active")
                                .font(.caption2)
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.15), in: Capsule())
                    }
                }

                Text("Will free \(selectedSize)")
                    .font(.headline)
            }

            Spacer()

            // Quick actions
            Button("Select All") {
                selectedItems = Set(allCleanupItems.map(\.id))
                selectedGitItems = Set(gitArtifacts.map(\.id))
            }
            .glassButton()

            Button("Select Stale Only") {
                selectStaleOnly()
            }
            .glassButton()
            .help("Select only projects not modified in the last 48 hours")

            Button("Clean Selected") {
                showingConfirmation = true
            }
            .glassButton(prominent: true)
            .tint(.red)
            .disabled(selectedItems.isEmpty && selectedGitItems.isEmpty)
        }
        .padding()
        .cleanupReview(
            isPresented: $showingConfirmation,
            items: selectedCleanupItems,
            disposition: .mixed,
            note: cleanConfirmationMessage,
            additionalCount: selectedGitCleanupItems.count,
            additionalBytes: selectedGitCleanupItems.reduce(0) { $0 + $1.size },
            additionalModules: Array(repeating: "Git", count: selectedGitCleanupItems.count),
            additionalPaths: selectedGitCleanupItems.map { $0.displayPath ?? $0.repositoryPath },
            onConfirm: { await cleanSelected() }
        )
    }

    private var cleanConfirmationMessage: String {
        var sections: [String] = []
        if !selectedItems.isEmpty {
            sections.append("Build artifacts are moved to Trash and can be regenerated by their developer tools.")
        }
        if !selectedGitItems.isEmpty {
            let commands = gitArtifacts
                .filter { selectedGitItems.contains($0.id) }
                .map { "• \($0.commandPreview)" }
                .joined(separator: "\n")
            sections.append(
                "Git cleanup runs these tool-native commands. " +
                "Worktree removal deletes that worktree directory rather than moving it to Trash:\n\(commands)"
            )
        }
        if recentlyModifiedCount > 0 {
            sections.insert(
                "Warning: \(recentlyModifiedCount) selected project(s) were modified recently " +
                "and may be in active development.",
                at: 0
            )
        }
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Actions

    private func scan() async {
        guard !isScanning else { return }
        isScanning = true
        isScanRunning = true
        projects = []
        projectCleanupItems = []
        systemArtifacts = []
        gitArtifacts = []
        selectedItems = []
        selectedGitItems = []

        defer {
            isScanning = false
            isScanRunning = false
            hasCompletedScan = true
        }

        // Scan for projects
        let scanner = ProjectScanner()
        projects = await scanner.discoverProjects(in: FileManager.default.homeDirectoryForCurrentUser)
        projectCleanupItems = await buildCleanupItems(for: projects)

        // Scan for system artifacts (DerivedData, etc.)
        let module = DevToolsModule()
        systemArtifacts = (try? await module.scan()) ?? []

        // Filter out duplicates
        let projectPaths = Set(projects.flatMap(\.artifactPaths).map(\.path))
        systemArtifacts = systemArtifacts.filter { !projectPaths.contains($0.path.path) }

        let gitScanner = GitArtifactScanner()
        gitToolStatus = await gitScanner.toolStatus()
        gitArtifacts = await gitScanner.discoverStaleArtifacts()
    }

    private func toggleProject(_ project: ProjectInfo) {
        let itemIDs = cleanupItemIDs(for: project)
        guard !itemIDs.isEmpty else { return }

        if itemIDs.allSatisfy({ selectedItems.contains($0) }) {
            selectedItems.subtract(itemIDs)
        } else {
            selectedItems.formUnion(itemIDs)
        }
    }

    private func toggleGitItem(_ item: GitCleanupItem) {
        if selectedGitItems.contains(item.id) {
            selectedGitItems.remove(item.id)
        } else {
            selectedGitItems.insert(item.id)
        }
    }

    private func selectStaleOnly() {
        // Select only projects that haven't been modified recently (not in last 48 hours)
        let staleProjectIds = Set(
            projects.filter { !$0.isModifiedRecently }.flatMap { project in
                allCleanupItems.filter { item in
                    project.artifactPaths.contains(item.path)
                }.map(\.id)
            }
        )

        // Also include system artifacts (DerivedData, etc.) that are safe
        let systemIds = Set(systemArtifacts.map(\.id))

        selectedItems = staleProjectIds.union(systemIds)
        selectedGitItems = Set(gitArtifacts.map(\.id))
    }

    private func cleanSelected() async -> CleanupResult? {
        let itemsToClean = selectedCleanupItems
        let gitItemsToClean = selectedGitCleanupItems

        // Route through ScanEngine so the full safety pipeline (per-item
        // SafetyChecker + aggregate DeletionGuard cap) applies, not just the
        // module's own delete. A blocked delete throws and is caught here.
        var failures: [String] = []
        var processed = 0
        var bytesFreed: Int64 = 0
        var cleanupErrors: [CleanupError] = []
        if !itemsToClean.isEmpty {
            let engine = ScanEngine()
            do {
                let result = try await engine.clean(items: itemsToClean, dryRun: false, confirmedLargeDeletion: true)
                processed += result.itemsProcessed
                bytesFreed += result.bytesFreed
                cleanupErrors.append(contentsOf: result.errors)
                if let summary = result.failureSummaryMessage {
                    failures.append(summary)
                }
            } catch {
                let message = "Cleanup failed: \(error.localizedDescription)"
                failures.append(message)
                cleanupErrors.append(CleanupError(
                    path: itemsToClean.first?.path ?? URL(string: "macsweep-action://dev-tools/cleanup")!,
                    message: message,
                    underlyingError: error
                ))
            }
        }

        if !gitItemsToClean.isEmpty {
            let result = await GitArtifactCleaner().clean(items: gitItemsToClean, dryRun: false)
            processed += result.itemsProcessed
            bytesFreed += result.bytesFreed
            cleanupErrors.append(contentsOf: result.errors)
            if let summary = result.errors.failureSummaryMessage {
                failures.append("Git artifacts: \(summary)")
            }
        }

        scanState.errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")

        // Refresh
        await scan()
        return CleanupResult(itemsProcessed: processed, bytesFreed: bytesFreed, errors: cleanupErrors)
    }

    // MARK: - Computed

    private var filteredProjects: [ProjectInfo] {
        if let filterType = filterType {
            return projects.filter { $0.type == filterType }
        }
        return projects
    }

    private var availableTypes: [ProjectType] {
        let types = Set(projects.map(\.type))
        return ProjectType.allCases.filter { types.contains($0) }
    }

    private var allCleanupItems: [CleanupItem] {
        (projectCleanupItems + systemArtifacts).sorted { $0.size > $1.size }
    }

    private var selectedSize: String {
        let gitTotal = gitArtifacts
            .filter { selectedGitItems.contains($0.id) }
            .reduce(0) { $0 + $1.size }
        let total = allCleanupItems.totalSize(selected: selectedItems) + gitTotal
        return total.formattedFileSize
    }

    private var selectedCount: Int {
        selectedItems.count + selectedGitItems.count
    }

    private var selectedCleanupItems: [CleanupItem] {
        allCleanupItems.filter { selectedItems.contains($0.id) }
    }

    private var selectedGitCleanupItems: [GitCleanupItem] {
        gitArtifacts.filter { selectedGitItems.contains($0.id) }
    }

    private var recentlyModifiedCount: Int {
        // Count how many selected items belong to recently modified projects
        var count = 0
        for project in projects where project.isModifiedRecently {
            let hasSelectedArtifact = allCleanupItems.contains { item in
                project.artifactPaths.contains(item.path) && selectedItems.contains(item.id)
            }
            if hasSelectedArtifact {
                count += 1
            }
        }
        return count
    }

    private func totalSizeForType(_ type: ProjectType) -> String {
        let total = projects.filter { $0.type == type }.reduce(0) { $0 + $1.artifactSize }
        return total.formattedFileSize
    }

    private func cleanupItemIDs(for project: ProjectInfo) -> Set<UUID> {
        Set(projectCleanupItems.filter { project.artifactPaths.contains($0.path) }.map(\.id))
    }

    private func buildCleanupItems(for projects: [ProjectInfo]) async -> [CleanupItem] {
        var items: [CleanupItem] = []
        for project in projects {
            for path in project.artifactPaths {
                let size = (try? await DiskAnalyzer.directorySize(at: path)) ?? 0
                let lastModified = try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                items.append(CleanupItem(
                    id: UUID(),
                    path: path,
                    size: size,
                    type: .directory,
                    module: "dev-tools",
                    moduleName: "\(project.type.rawValue) - \(project.name)",
                    lastModified: lastModified
                ))
            }
        }
        return items
    }
}

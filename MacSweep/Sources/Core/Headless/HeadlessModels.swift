import Foundation

public enum HeadlessPermissionKind: String, Codable, Sendable {
    case fullDiskAccess
}

public struct HeadlessPermissionRequirement: Codable, Sendable {
    public let kind: HeadlessPermissionKind
    public let granted: Bool

    public init(kind: HeadlessPermissionKind, granted: Bool) {
        self.kind = kind
        self.granted = granted
    }
}

public struct HeadlessModulePermissionStatus: Codable, Sendable {
    public let moduleID: String
    public let moduleName: String
    public let requirements: [HeadlessPermissionRequirement]
    public let allRequirementsSatisfied: Bool

    public init(
        moduleID: String,
        moduleName: String,
        requirements: [HeadlessPermissionRequirement],
        allRequirementsSatisfied: Bool
    ) {
        self.moduleID = moduleID
        self.moduleName = moduleName
        self.requirements = requirements
        self.allRequirementsSatisfied = allRequirementsSatisfied
    }
}

public struct HeadlessPermissionStatusReport: Codable, Sendable {
    public let fullDiskAccessGranted: Bool
    public let modules: [HeadlessModulePermissionStatus]

    public init(fullDiskAccessGranted: Bool, modules: [HeadlessModulePermissionStatus]) {
        self.fullDiskAccessGranted = fullDiskAccessGranted
        self.modules = modules
    }
}

public struct HeadlessModuleDescriptor: Codable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let requiredPermissions: [HeadlessPermissionKind]

    public init(id: String, name: String, description: String, requiredPermissions: [HeadlessPermissionKind]) {
        self.id = id
        self.name = name
        self.description = description
        self.requiredPermissions = requiredPermissions
    }
}

public struct HeadlessCleanupError: Codable, Sendable {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

public struct HeadlessFinding: Codable, Sendable {
    public let id: String
    public let module: String
    public let moduleName: String
    public let path: String
    public let size: Int64
    public let type: String
    public let lastModified: Date?
    public let recommended: Bool
    public let reviewReason: String?

    public init(
        id: String,
        module: String,
        moduleName: String,
        path: String,
        size: Int64,
        type: String,
        lastModified: Date?,
        recommended: Bool,
        reviewReason: String? = nil
    ) {
        self.id = id
        self.module = module
        self.moduleName = moduleName
        self.path = path
        self.size = size
        self.type = type
        self.lastModified = lastModified
        self.recommended = recommended
        self.reviewReason = reviewReason
    }
}

public struct HeadlessSummary: Codable, Sendable {
    public let score: Int
    public let reclaimableBytes: Int64
    public let totalFindings: Int
    public let issueCount: Int
    public let categoryCount: Int
    public let recommendedFindings: Int
    public let recommendedBytes: Int64
    public let errors: [HeadlessCleanupError]

    public init(
        score: Int,
        reclaimableBytes: Int64,
        totalFindings: Int,
        issueCount: Int,
        categoryCount: Int,
        recommendedFindings: Int,
        recommendedBytes: Int64,
        errors: [HeadlessCleanupError]
    ) {
        self.score = score
        self.reclaimableBytes = reclaimableBytes
        self.totalFindings = totalFindings
        self.issueCount = issueCount
        self.categoryCount = categoryCount
        self.recommendedFindings = recommendedFindings
        self.recommendedBytes = recommendedBytes
        self.errors = errors
    }
}

public struct HeadlessScanResult: Codable, Sendable {
    public let executedModules: [String]
    public let permissions: HeadlessPermissionStatusReport
    public let findings: [HeadlessFinding]
    public let summary: HeadlessSummary

    public init(
        executedModules: [String],
        permissions: HeadlessPermissionStatusReport,
        findings: [HeadlessFinding],
        summary: HeadlessSummary
    ) {
        self.executedModules = executedModules
        self.permissions = permissions
        self.findings = findings
        self.summary = summary
    }
}

public struct HeadlessCleanupResult: Codable, Sendable {
    public let dryRun: Bool
    public let itemsProcessed: Int
    public let bytesFreed: Int64
    public let errors: [HeadlessCleanupError]

    public init(
        dryRun: Bool,
        itemsProcessed: Int,
        bytesFreed: Int64,
        errors: [HeadlessCleanupError]
    ) {
        self.dryRun = dryRun
        self.itemsProcessed = itemsProcessed
        self.bytesFreed = bytesFreed
        self.errors = errors
    }
}

public struct HeadlessApplyResult: Codable, Sendable {
    public let scan: HeadlessScanResult
    public let cleanup: HeadlessCleanupResult

    public init(scan: HeadlessScanResult, cleanup: HeadlessCleanupResult) {
        self.scan = scan
        self.cleanup = cleanup
    }
}

public struct HeadlessMaintenanceActionDescriptor: Codable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let requiresAdmin: Bool

    public init(id: String, name: String, description: String, requiresAdmin: Bool) {
        self.id = id
        self.name = name
        self.description = description
        self.requiresAdmin = requiresAdmin
    }
}

public struct HeadlessMaintenanceRunResult: Codable, Sendable {
    public let action: HeadlessMaintenanceActionDescriptor
    public let success: Bool
    public let message: String
    public let bytesFreed: Int64

    public init(
        action: HeadlessMaintenanceActionDescriptor,
        success: Bool,
        message: String,
        bytesFreed: Int64
    ) {
        self.action = action
        self.success = success
        self.message = message
        self.bytesFreed = bytesFreed
    }
}

public struct HeadlessSelectionRequest: Sendable, Equatable {
    public let moduleIDs: [String]?
    public let smartCare: Bool

    public init(moduleIDs: [String]? = nil, smartCare: Bool = false) {
        self.moduleIDs = moduleIDs
        self.smartCare = smartCare
    }
}

public final class HeadlessPreparedCleanupPlan: @unchecked Sendable {
    public let scan: HeadlessScanResult
    public let cleanupPreview: HeadlessCleanupResult
    let selectedItems: [CleanupItem]

    init(scan: HeadlessScanResult, cleanupPreview: HeadlessCleanupResult, selectedItems: [CleanupItem]) {
        self.scan = scan
        self.cleanupPreview = cleanupPreview
        self.selectedItems = selectedItems
    }
}

// MARK: - Disk Usage

public struct HeadlessDiskUsage: Codable, Sendable {
    public let totalBytes: Int64
    public let usedBytes: Int64
    public let freeBytes: Int64
    public let usedPercentage: Double
    public let freePercentage: Double

    public init(
        totalBytes: Int64,
        usedBytes: Int64,
        freeBytes: Int64,
        usedPercentage: Double,
        freePercentage: Double
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
        self.usedPercentage = usedPercentage
        self.freePercentage = freePercentage
    }
}

// MARK: - Login Items

public enum HeadlessLoginItemKind: String, Codable, Sendable {
    case appService
    case launchAgent
    case launchDaemon
}

public struct HeadlessLoginItem: Codable, Sendable {
    public let name: String
    public let path: String
    public let kind: HeadlessLoginItemKind
    public let bundleIdentifier: String?
    public let enabled: Bool
    /// Exact on-disk plist path for launch agents/daemons; nil for SMAppService.
    public let plistPath: String?

    public init(
        name: String,
        path: String,
        kind: HeadlessLoginItemKind,
        bundleIdentifier: String?,
        enabled: Bool,
        plistPath: String? = nil
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.bundleIdentifier = bundleIdentifier
        self.enabled = enabled
        self.plistPath = plistPath
    }
}

public struct HeadlessLoginItemsReport: Codable, Sendable {
    public let totalItems: Int
    public let items: [HeadlessLoginItem]

    public init(totalItems: Int, items: [HeadlessLoginItem]) {
        self.totalItems = totalItems
        self.items = items
    }
}

public struct HeadlessLoginItemMutationResult: Codable, Sendable {
    public let label: String
    public let plistPath: String
    public let kind: HeadlessLoginItemKind
    public let action: String   // "enable" | "disable" | "remove"
    public let enabled: Bool
    public let removed: Bool

    public init(
        label: String,
        plistPath: String,
        kind: HeadlessLoginItemKind,
        action: String,
        enabled: Bool,
        removed: Bool
    ) {
        self.label = label
        self.plistPath = plistPath
        self.kind = kind
        self.action = action
        self.enabled = enabled
        self.removed = removed
    }
}

// MARK: - Space Lens (disk tree)

public struct HeadlessDiskNode: Codable, Sendable {
    public let name: String
    public let path: String
    public let size: Int64
    public let isDirectory: Bool
    /// Coarse type classifier: "directory" for folders, otherwise the lowercased
    /// file extension (e.g. "log", "zip") or "file" when there is none. Lets agents
    /// reason about what a large leaf node is without re-stat'ing the path.
    public let fileType: String
    public let lastModified: Date?
    /// Number of direct children retained after any `--min-size` pruning (the
    /// `children` array is the full, depth-bounded, post-filter set).
    public let childCount: Int
    public let children: [HeadlessDiskNode]

    public init(
        name: String,
        path: String,
        size: Int64,
        isDirectory: Bool,
        fileType: String,
        lastModified: Date?,
        childCount: Int,
        children: [HeadlessDiskNode]
    ) {
        self.name = name
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
        self.fileType = fileType
        self.lastModified = lastModified
        self.childCount = childCount
        self.children = children
    }
}

public struct HeadlessDiskTree: Codable, Sendable {
    public let rootPath: String
    public let depth: Int
    public let totalBytes: Int64
    public let root: HeadlessDiskNode

    public init(rootPath: String, depth: Int, totalBytes: Int64, root: HeadlessDiskNode) {
        self.rootPath = rootPath
        self.depth = depth
        self.totalBytes = totalBytes
        self.root = root
    }
}

// MARK: - Cache Analysis

public struct HeadlessCacheFinding: Codable, Sendable {
    public let path: String
    /// Exact on-disk size for deterministic fast-scan findings; `nil` for AI
    /// findings, whose sizes are free-text estimates (see `sizeText`).
    public let sizeBytes: Int64?
    public let sizeText: String
    public let category: String
    public let regeneratesAutomatically: Bool
    public let source: String
    public let reason: String?

    public init(
        path: String,
        sizeBytes: Int64?,
        sizeText: String,
        category: String,
        regeneratesAutomatically: Bool,
        source: String,
        reason: String?
    ) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.sizeText = sizeText
        self.category = category
        self.regeneratesAutomatically = regeneratesAutomatically
        self.source = source
        self.reason = reason
    }
}

public struct HeadlessCacheReport: Codable, Sendable {
    public let fastScanCount: Int
    public let aiScanRequested: Bool
    public let aiScanRan: Bool
    public let totalFindings: Int
    public let findings: [HeadlessCacheFinding]
    public let errors: [String]

    public init(
        fastScanCount: Int,
        aiScanRequested: Bool,
        aiScanRan: Bool,
        totalFindings: Int,
        findings: [HeadlessCacheFinding],
        errors: [String]
    ) {
        self.fastScanCount = fastScanCount
        self.aiScanRequested = aiScanRequested
        self.aiScanRan = aiScanRan
        self.totalFindings = totalFindings
        self.findings = findings
        self.errors = errors
    }
}

// MARK: - App Uninstall

public struct HeadlessAppLeftover: Codable, Sendable {
    public let path: String
    public let size: Int64
    public let type: String

    public init(path: String, size: Int64, type: String) {
        self.path = path
        self.size = size
        self.type = type
    }
}

public struct HeadlessInstalledApp: Codable, Sendable {
    public let id: String
    public let name: String
    public let bundlePath: String
    public let version: String?
    public let bundleSize: Int64
    public let leftoverBytes: Int64
    public let leftoverCount: Int
    public let totalSize: Int64
    public let lastUsed: Date?
    public let leftovers: [HeadlessAppLeftover]

    public init(
        id: String,
        name: String,
        bundlePath: String,
        version: String?,
        bundleSize: Int64,
        leftoverBytes: Int64,
        leftoverCount: Int,
        totalSize: Int64,
        lastUsed: Date?,
        leftovers: [HeadlessAppLeftover]
    ) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.version = version
        self.bundleSize = bundleSize
        self.leftoverBytes = leftoverBytes
        self.leftoverCount = leftoverCount
        self.totalSize = totalSize
        self.lastUsed = lastUsed
        self.leftovers = leftovers
    }
}

public struct HeadlessUninstallableAppsReport: Codable, Sendable {
    public let totalApps: Int
    public let totalReclaimableBytes: Int64
    public let apps: [HeadlessInstalledApp]

    public init(totalApps: Int, totalReclaimableBytes: Int64, apps: [HeadlessInstalledApp]) {
        self.totalApps = totalApps
        self.totalReclaimableBytes = totalReclaimableBytes
        self.apps = apps
    }
}

public struct HeadlessUninstallResult: Codable, Sendable {
    public let appID: String
    public let appName: String
    public let bundlePath: String
    public let dryRun: Bool
    public let removedApp: Bool
    public let itemsProcessed: Int
    public let bytesFreed: Int64
    public let leftoversRemoved: Int
    public let leftovers: [HeadlessAppLeftover]
    public let errors: [HeadlessCleanupError]

    public init(
        appID: String,
        appName: String,
        bundlePath: String,
        dryRun: Bool,
        removedApp: Bool,
        itemsProcessed: Int,
        bytesFreed: Int64,
        leftoversRemoved: Int,
        leftovers: [HeadlessAppLeftover],
        errors: [HeadlessCleanupError]
    ) {
        self.appID = appID
        self.appName = appName
        self.bundlePath = bundlePath
        self.dryRun = dryRun
        self.removedApp = removedApp
        self.itemsProcessed = itemsProcessed
        self.bytesFreed = bytesFreed
        self.leftoversRemoved = leftoversRemoved
        self.leftovers = leftovers
        self.errors = errors
    }
}

// MARK: - Malware Scan

public struct HeadlessThreatFinding: Codable, Sendable {
    public let id: String
    public let path: String
    public let category: String
    public let threatLevel: String
    public let description: String
    public let aiExplanation: String?
    public let remediation: String?
    /// `true` when the finding matched a known malware signature; `false` for
    /// review-tier findings that are merely unrecognized or unverifiable.
    public let isKnownSignature: Bool

    public init(
        id: String,
        path: String,
        category: String,
        threatLevel: String,
        description: String,
        aiExplanation: String?,
        remediation: String?,
        isKnownSignature: Bool
    ) {
        self.id = id
        self.path = path
        self.category = category
        self.threatLevel = threatLevel
        self.description = description
        self.aiExplanation = aiExplanation
        self.remediation = remediation
        self.isKnownSignature = isKnownSignature
    }

    // `id` and `isKnownSignature` were added after the CLI JSON contract
    // shipped; tolerate their absence so reports emitted by older builds still
    // decode. Encoding always writes both.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.path = try container.decode(String.self, forKey: .path)
        self.category = try container.decode(String.self, forKey: .category)
        self.threatLevel = try container.decode(String.self, forKey: .threatLevel)
        self.description = try container.decode(String.self, forKey: .description)
        self.aiExplanation = try container.decodeIfPresent(String.self, forKey: .aiExplanation)
        self.remediation = try container.decodeIfPresent(String.self, forKey: .remediation)
        self.isKnownSignature = try container.decodeIfPresent(Bool.self, forKey: .isKnownSignature) ?? false
    }
}

public struct HeadlessMalwareScanReport: Codable, Sendable {
    public let scannedAt: Date
    public let totalScanned: Int
    public let isClean: Bool
    public let xprotectStatus: String
    public let aiAnalysisRequested: Bool
    public let findings: [HeadlessThreatFinding]

    public init(
        scannedAt: Date,
        totalScanned: Int,
        isClean: Bool,
        xprotectStatus: String,
        aiAnalysisRequested: Bool,
        findings: [HeadlessThreatFinding]
    ) {
        self.scannedAt = scannedAt
        self.totalScanned = totalScanned
        self.isClean = isClean
        self.xprotectStatus = xprotectStatus
        self.aiAnalysisRequested = aiAnalysisRequested
        self.findings = findings
    }
}

// MARK: - Homebrew

public struct HeadlessBrewPackage: Codable, Sendable {
    public let name: String
    public let currentVersion: String
    public let latestVersion: String

    public init(name: String, currentVersion: String, latestVersion: String) {
        self.name = name
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
    }
}

public struct HeadlessHomebrewReport: Codable, Sendable {
    public let outdatedCount: Int
    public let packages: [HeadlessBrewPackage]

    public init(outdatedCount: Int, packages: [HeadlessBrewPackage]) {
        self.outdatedCount = outdatedCount
        self.packages = packages
    }
}

public struct HeadlessHomebrewUpgradeResult: Codable, Sendable {
    public let upgraded: Bool
    public let log: String
    public let remainingOutdated: [HeadlessBrewPackage]

    public init(upgraded: Bool, log: String, remainingOutdated: [HeadlessBrewPackage]) {
        self.upgraded = upgraded
        self.log = log
        self.remainingOutdated = remainingOutdated
    }
}

public struct HeadlessHomebrewCleanupResult: Codable, Sendable {
    public let success: Bool
    public let reclaimedText: String?
    public let log: String

    public init(success: Bool, reclaimedText: String?, log: String) {
        self.success = success
        self.reclaimedText = reclaimedText
        self.log = log
    }
}

public struct HeadlessHomebrewLeavesReport: Codable, Sendable {
    public let count: Int
    public let leaves: [String]

    public init(count: Int, leaves: [String]) {
        self.count = count
        self.leaves = leaves
    }
}

// MARK: - Shred

public struct HeadlessShredResult: Codable, Sendable {
    public let path: String
    public let level: String
    public let isDirectory: Bool
    public let filesShredded: Int
    public let bytesShredded: Int64
    public let success: Bool
    public let errors: [String]

    public init(
        path: String,
        level: String,
        isDirectory: Bool,
        filesShredded: Int,
        bytesShredded: Int64,
        success: Bool,
        errors: [String]
    ) {
        self.path = path
        self.level = level
        self.isDirectory = isDirectory
        self.filesShredded = filesShredded
        self.bytesShredded = bytesShredded
        self.success = success
        self.errors = errors
    }
}

// MARK: - Network: WiFi

public struct HeadlessWiFiNetwork: Codable, Sendable {
    public let ssid: String
    public let isConnected: Bool

    public init(ssid: String, isConnected: Bool) {
        self.ssid = ssid
        self.isConnected = isConnected
    }
}

public struct HeadlessWiFiReport: Codable, Sendable {
    public let currentSSID: String?
    public let totalNetworks: Int
    public let networks: [HeadlessWiFiNetwork]

    public init(currentSSID: String?, totalNetworks: Int, networks: [HeadlessWiFiNetwork]) {
        self.currentSSID = currentSSID
        self.totalNetworks = totalNetworks
        self.networks = networks
    }
}

public struct HeadlessWiFiRemoveResult: Codable, Sendable {
    public let ssid: String
    public let removed: Bool

    public init(ssid: String, removed: Bool) {
        self.ssid = ssid
        self.removed = removed
    }
}

// MARK: - Network: SSH Known Hosts

public struct HeadlessSSHKnownHost: Codable, Sendable {
    public let host: String
    public let algorithm: String
    public let isHashed: Bool

    public init(host: String, algorithm: String, isHashed: Bool) {
        self.host = host
        self.algorithm = algorithm
        self.isHashed = isHashed
    }
}

public struct HeadlessSSHReport: Codable, Sendable {
    public let totalHosts: Int
    public let hosts: [HeadlessSSHKnownHost]

    public init(totalHosts: Int, hosts: [HeadlessSSHKnownHost]) {
        self.totalHosts = totalHosts
        self.hosts = hosts
    }
}

public struct HeadlessSSHRemoveResult: Codable, Sendable {
    public let target: String
    public let removedCount: Int
    public let clearedAll: Bool

    public init(target: String, removedCount: Int, clearedAll: Bool) {
        self.target = target
        self.removedCount = removedCount
        self.clearedAll = clearedAll
    }
}

// MARK: - Processes

public struct HeadlessProcess: Codable, Sendable {
    public let pid: Int32
    public let name: String
    public let bundleID: String?
    public let memoryMB: Double
    public let cpuPercent: Double
    public let isActive: Bool

    public init(
        pid: Int32,
        name: String,
        bundleID: String?,
        memoryMB: Double,
        cpuPercent: Double,
        isActive: Bool
    ) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.memoryMB = memoryMB
        self.cpuPercent = cpuPercent
        self.isActive = isActive
    }
}

public struct HeadlessProcessReport: Codable, Sendable {
    public let sortOrder: String   // "memory" | "cpu" | "name"
    public let totalProcesses: Int
    public let processes: [HeadlessProcess]

    public init(sortOrder: String, totalProcesses: Int, processes: [HeadlessProcess]) {
        self.sortOrder = sortOrder
        self.totalProcesses = totalProcesses
        self.processes = processes
    }
}

public struct HeadlessProcessQuitResult: Codable, Sendable {
    public let pid: Int32
    public let name: String
    public let forced: Bool
    public let terminated: Bool

    public init(pid: Int32, name: String, forced: Bool, terminated: Bool) {
        self.pid = pid
        self.name = name
        self.forced = forced
        self.terminated = terminated
    }
}

// MARK: - Privacy Actions

public struct HeadlessPrivacyActionResult: Codable, Sendable {
    public let action: String   // "clear-clipboard" | "clear-terminal-history" | "clear-recent-docs"
    public let success: Bool
    public let message: String

    public init(action: String, success: Bool, message: String) {
        self.action = action
        self.success = success
        self.message = message
    }
}

// MARK: - System Monitor

public struct HeadlessCPUReport: Codable, Sendable {
    public let userPercent: Double
    public let systemPercent: Double
    public let idlePercent: Double
    public let totalPercent: Double
    public let temperatureCelsius: Double?

    public init(
        userPercent: Double,
        systemPercent: Double,
        idlePercent: Double,
        totalPercent: Double,
        temperatureCelsius: Double?
    ) {
        self.userPercent = userPercent
        self.systemPercent = systemPercent
        self.idlePercent = idlePercent
        self.totalPercent = totalPercent
        self.temperatureCelsius = temperatureCelsius
    }
}

public struct HeadlessMemoryReport: Codable, Sendable {
    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let freeBytes: UInt64
    public let wiredBytes: UInt64
    public let activeBytes: UInt64
    public let inactiveBytes: UInt64
    public let compressedBytes: UInt64
    public let availableBytes: UInt64
    public let usedPercentage: Double
    public let pressureLevel: String   // "normal" | "warning" | "critical"

    public init(
        totalBytes: UInt64,
        usedBytes: UInt64,
        freeBytes: UInt64,
        wiredBytes: UInt64,
        activeBytes: UInt64,
        inactiveBytes: UInt64,
        compressedBytes: UInt64,
        availableBytes: UInt64,
        usedPercentage: Double,
        pressureLevel: String
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
        self.wiredBytes = wiredBytes
        self.activeBytes = activeBytes
        self.inactiveBytes = inactiveBytes
        self.compressedBytes = compressedBytes
        self.availableBytes = availableBytes
        self.usedPercentage = usedPercentage
        self.pressureLevel = pressureLevel
    }
}

public struct HeadlessBatteryReport: Codable, Sendable {
    public let hasBattery: Bool
    public let percentage: Int
    public let isCharging: Bool
    public let isPluggedIn: Bool
    public let timeRemainingMinutes: Int?
    public let cycleCount: Int?
    public let healthPercent: Int?
    public let statusText: String

    public init(
        hasBattery: Bool,
        percentage: Int,
        isCharging: Bool,
        isPluggedIn: Bool,
        timeRemainingMinutes: Int?,
        cycleCount: Int?,
        healthPercent: Int?,
        statusText: String
    ) {
        self.hasBattery = hasBattery
        self.percentage = percentage
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.timeRemainingMinutes = timeRemainingMinutes
        self.cycleCount = cycleCount
        self.healthPercent = healthPercent
        self.statusText = statusText
    }
}

/// A connected Bluetooth peripheral and its battery levels, as reported by
/// `macsweep monitor`. Any of the battery fields may be null when unavailable.
public struct HeadlessConnectedDevice: Codable, Sendable {
    public let name: String
    public let type: String
    public let battery: Int?
    public let batteryLeft: Int?
    public let batteryRight: Int?
    public let batteryCase: Int?

    public init(
        name: String,
        type: String,
        battery: Int?,
        batteryLeft: Int?,
        batteryRight: Int?,
        batteryCase: Int?
    ) {
        self.name = name
        self.type = type
        self.battery = battery
        self.batteryLeft = batteryLeft
        self.batteryRight = batteryRight
        self.batteryCase = batteryCase
    }
}

public struct HeadlessNetworkReport: Codable, Sendable {
    public let downloadSpeedBytesPerSec: UInt64
    public let uploadSpeedBytesPerSec: UInt64
    public let totalDownloadedBytes: UInt64
    public let totalUploadedBytes: UInt64
    public let isConnected: Bool
    public let interfaceName: String?
    public let ssid: String?

    public init(
        downloadSpeedBytesPerSec: UInt64,
        uploadSpeedBytesPerSec: UInt64,
        totalDownloadedBytes: UInt64,
        totalUploadedBytes: UInt64,
        isConnected: Bool,
        interfaceName: String?,
        ssid: String?
    ) {
        self.downloadSpeedBytesPerSec = downloadSpeedBytesPerSec
        self.uploadSpeedBytesPerSec = uploadSpeedBytesPerSec
        self.totalDownloadedBytes = totalDownloadedBytes
        self.totalUploadedBytes = totalUploadedBytes
        self.isConnected = isConnected
        self.interfaceName = interfaceName
        self.ssid = ssid
    }
}

public struct HeadlessMonitorReport: Codable, Sendable {
    public let chipName: String
    public let cpu: HeadlessCPUReport
    public let memory: HeadlessMemoryReport
    public let battery: HeadlessBatteryReport
    public let network: HeadlessNetworkReport
    public let connectedDevices: [HeadlessConnectedDevice]

    public init(
        chipName: String,
        cpu: HeadlessCPUReport,
        memory: HeadlessMemoryReport,
        battery: HeadlessBatteryReport,
        network: HeadlessNetworkReport,
        connectedDevices: [HeadlessConnectedDevice] = []
    ) {
        self.chipName = chipName
        self.cpu = cpu
        self.memory = memory
        self.battery = battery
        self.network = network
        self.connectedDevices = connectedDevices
    }
}

/// Current state of the weekly background-scan schedule, as steered by the GUI
/// scheduler and reported/edited through `macsweep schedule`.
public struct HeadlessScheduleReport: Codable, Sendable {
    public let intervalDays: Int
    public let intervalSeconds: Int
    public let nextScheduledScan: Date?
    public let minIntervalDays: Int
    public let maxIntervalDays: Int

    public init(
        intervalDays: Int,
        intervalSeconds: Int,
        nextScheduledScan: Date?,
        minIntervalDays: Int,
        maxIntervalDays: Int
    ) {
        self.intervalDays = intervalDays
        self.intervalSeconds = intervalSeconds
        self.nextScheduledScan = nextScheduledScan
        self.minIntervalDays = minIntervalDays
        self.maxIntervalDays = maxIntervalDays
    }
}

/// Result of `macsweep self-update`. Without `--yes` this just reports the version
/// and the upgrade command (`applied == false`, `log == nil`); with `--yes` it
/// reflects the executed `brew upgrade`.
public struct HeadlessSelfUpdateResult: Codable, Sendable {
    public let currentVersion: String
    public let upgradeCommand: String
    public let applied: Bool
    public let log: String?

    public init(currentVersion: String, upgradeCommand: String, applied: Bool, log: String?) {
        self.currentVersion = currentVersion
        self.upgradeCommand = upgradeCommand
        self.applied = applied
        self.log = log
    }
}

public enum HeadlessServiceError: Error, LocalizedError, Sendable {
    case conflictingSelection
    case invalidModules([String])
    case unknownMaintenanceAction(String)
    case pathNotFound(String)
    case shredRefused(String)
    case homebrewNotInstalled
    case appNotFound(String)
    case appRunning(String)
    case ambiguousAppMatch(String, [String])
    case uninstallFailed(String)
    case loginItemNotFound(String)
    case loginItemAmbiguous(String, [String])
    case loginItemMutationFailed(String)
    case wifiNetworkNotFound(String)
    case sshHostNotFound(String)
    case processNotFound(String)
    case processQuitRefused(String)
    case processAmbiguous(String, [String])
    case unknownPrivacyAction(String)
    case networkOperationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .conflictingSelection:
            return "Use either --modules or --smart-care, not both."
        case .invalidModules(let modules):
            return "Unknown modules: \(modules.joined(separator: ", "))."
        case .unknownMaintenanceAction(let action):
            return "Unknown maintenance action: \(action)."
        case .pathNotFound(let path):
            return "Path not found: \(path)."
        case .shredRefused(let reason):
            return "Refusing to shred: \(reason)."
        case .homebrewNotInstalled:
            return "Homebrew is not installed (no brew binary at /opt/homebrew or /usr/local)."
        case .appNotFound(let query):
            return "No installed application matched: \(query)."
        case .appRunning(let name):
            return "Quit \(name) before uninstalling it."
        case .ambiguousAppMatch(let query, let matches):
            return "Multiple apps match '\(query)': \(matches.joined(separator: ", ")). Use the exact bundle identifier."
        case .uninstallFailed(let reason):
            return "Uninstall failed: \(reason)."
        case .loginItemNotFound(let label):
            return "No login item matched: \(label). Use the exact Label from 'login-items list'."
        case .loginItemAmbiguous(let label, let paths):
            return "Multiple login item plists match '\(label)': \(paths.joined(separator: ", ")). Remove or rename the duplicate."
        case .loginItemMutationFailed(let reason):
            return "Login item update failed: \(reason)."
        case .wifiNetworkNotFound(let ssid):
            return "No saved WiFi network matched: \(ssid). Use the exact SSID from 'network wifi list'."
        case .sshHostNotFound(let host):
            return "No SSH known host matched: \(host). Use the exact host from 'network ssh list'."
        case .processNotFound(let query):
            return "No running process matched: \(query)."
        case .processQuitRefused(let reason):
            return "Refusing to quit \(reason)."
        case .processAmbiguous(let query, let matches):
            return "Multiple processes match '\(query)': \(matches.joined(separator: ", ")). Use the exact PID."
        case .unknownPrivacyAction(let action):
            return "Unknown privacy action: \(action). Valid: clear-clipboard, clear-terminal-history, clear-recent-docs."
        case .networkOperationFailed(let reason):
            return "Network operation failed: \(reason)."
        }
    }
}

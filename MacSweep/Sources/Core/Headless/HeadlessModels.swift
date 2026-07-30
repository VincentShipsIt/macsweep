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

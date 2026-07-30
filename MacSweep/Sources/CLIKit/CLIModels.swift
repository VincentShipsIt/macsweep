import Foundation
import Darwin
import MacSweepCore

struct CLICommandMetadata: Codable {
    let command: String
    let timestamp: Date
    let executedModules: [String]
}

struct CLIScanOutput: Codable {
    let metadata: CLICommandMetadata
    let permissions: HeadlessPermissionStatusReport
    let findings: [HeadlessFinding]
    let summary: HeadlessSummary
    let cleanup: HeadlessCleanupResult?
}

struct CLIModulesOutput: Codable {
    let metadata: CLICommandMetadata
    let modules: [HeadlessModuleDescriptor]
}

struct CLIPermissionsOutput: Codable {
    let metadata: CLICommandMetadata
    let permissions: HeadlessPermissionStatusReport
}

struct CLIMaintenanceOutput: Codable {
    let metadata: CLICommandMetadata
    let result: HeadlessMaintenanceRunResult
}

struct CLIMaintenanceListOutput: Codable {
    let metadata: CLICommandMetadata
    let actions: [HeadlessMaintenanceActionDescriptor]
}

struct CLIVersionOutput: Codable {
    let metadata: CLICommandMetadata
    let version: String
}

struct CLISpaceOutput: Codable {
    let metadata: CLICommandMetadata
    let disk: HeadlessDiskUsage
}

struct CLILoginItemsOutput: Codable {
    let metadata: CLICommandMetadata
    let report: HeadlessLoginItemsReport
}

struct CLILoginItemMutationOutput: Codable {
    let metadata: CLICommandMetadata
    let result: HeadlessLoginItemMutationResult
}

struct CLISpaceLensOutput: Codable {
    let metadata: CLICommandMetadata
    let tree: HeadlessDiskTree
}

struct CLIUninstallListOutput: Codable {
    let metadata: CLICommandMetadata
    let report: HeadlessUninstallableAppsReport
}

struct CLIUninstallOutput: Codable {
    let metadata: CLICommandMetadata
    let result: HeadlessUninstallResult
}

struct CLIAIOutput: Codable {
    let metadata: CLICommandMetadata
    let report: HeadlessCacheReport
}

struct CLIMalwareOutput: Codable {
    let metadata: CLICommandMetadata
    let report: HeadlessMalwareScanReport
}

struct CLIHomebrewOutput: Codable {
    let metadata: CLICommandMetadata
    let report: HeadlessHomebrewReport
}

struct CLIHomebrewUpgradeOutput: Codable {
    let metadata: CLICommandMetadata
    let result: HeadlessHomebrewUpgradeResult
}

struct CLIHomebrewCleanupOutput: Codable {
    let metadata: CLICommandMetadata
    let result: HeadlessHomebrewCleanupResult
}

struct CLIHomebrewLeavesOutput: Codable {
    let metadata: CLICommandMetadata
    let report: HeadlessHomebrewLeavesReport
}

struct CLIShredOutput: Codable {
    let metadata: CLICommandMetadata
    let result: HeadlessShredResult
}

struct CLIWiFiListOutput: Codable {
    let metadata: CLICommandMetadata
    let report: HeadlessWiFiReport
}

struct CLIWiFiRemoveOutput: Codable {
    let metadata: CLICommandMetadata
    let result: HeadlessWiFiRemoveResult
}

struct CLISSHListOutput: Codable {
    let metadata: CLICommandMetadata
    let report: HeadlessSSHReport
}

struct CLISSHRemoveOutput: Codable {
    let metadata: CLICommandMetadata
    let result: HeadlessSSHRemoveResult
}

struct CLIProcessesListOutput: Codable {
    let metadata: CLICommandMetadata
    let report: HeadlessProcessReport
}

struct CLIProcessQuitOutput: Codable {
    let metadata: CLICommandMetadata
    let result: HeadlessProcessQuitResult
}

struct CLIPrivacyOutput: Codable {
    let metadata: CLICommandMetadata
    let result: HeadlessPrivacyActionResult
}

struct CLIMonitorOutput: Codable {
    let metadata: CLICommandMetadata
    let report: HeadlessMonitorReport
}

struct CLIScheduleOutput: Codable {
    let metadata: CLICommandMetadata
    let report: HeadlessScheduleReport
}

struct CLISelfUpdateOutput: Codable {
    let metadata: CLICommandMetadata
    let result: HeadlessSelfUpdateResult
}

enum CLIExecutionError: Error, LocalizedError {
    case confirmationRequired
    case cleanupCancelled

    var errorDescription: String? {
        switch self {
        case .confirmationRequired:
            return "Refusing destructive operation without --yes in non-interactive mode."
        case .cleanupCancelled:
            return "Operation cancelled."
        }
    }
}

/// Semantic process exit codes for agent/script consumers. Stable contract:
/// a nonzero code distinguishes usage errors, missing targets, refusals, and
/// confirmation gates from generic failures.
public enum CLIExitCode: Int32 {
    case success = 0
    case generic = 1
    case usage = 2
    case confirmationRequired = 3
    case notFound = 4
    case refused = 5
    // A read-only scan that COMPLETED but surfaced a genuine threat
    // (suspicious/malicious). Distinct from `generic` so an agent can branch on
    // "threats found" without conflating it with an operational error. `review`
    // items are not threats and do NOT trigger this — only `!isClean` does.
    case threatsFound = 6
    // `homebrew outdated` completed and found one or more packages with a newer
    // version. Distinct from `generic` so an agent/script can branch on "updates
    // exist" (like `git diff --exit-code`) without parsing output. Zero outdated
    // → success. Not in `exitCode(for:)`: it's a success-path result, not an error.
    case updatesAvailable = 7
    // The user declined an interactive confirmation (typed N). Distinct from
    // `generic` so an agent can tell a deliberate user cancellation apart from an
    // operational failure — nothing went wrong, the operation just didn't run.
    case cancelled = 8
}


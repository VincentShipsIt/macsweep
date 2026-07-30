import Foundation

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

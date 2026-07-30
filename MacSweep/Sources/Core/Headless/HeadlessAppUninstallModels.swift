import Foundation

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


import Foundation

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


import Foundation

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


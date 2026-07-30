import Foundation

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


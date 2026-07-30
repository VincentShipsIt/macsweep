import Foundation
import CoreWLAN
import SystemConfiguration

/// Module for cleaning network-related data
struct NetworkModule: ScanModule {
    let id = "network"
    let name = "Network"
    let description = "Clean WiFi networks, SSH keys, DNS cache, and network caches"
    let icon = "network"

    func scan() async throws -> [CleanupItem] {
        var items: [CleanupItem] = []

        // Network service proxy cache — a true regenerable cache living under
        // ~/Library/Caches. This is the only thing this module sweeps.
        //
        // Deliberately NOT scanned (these are security/correctness hazards, not
        // disk space, and a cleaner must never touch them automatically):
        //   • ~/.ssh/known_hosts[.old] — host-key pinning state. Wiping it
        //     silently re-trusts every host on the next connection (MITM
        //     exposure). ~/.ssh is in neverDelete; deliberate per-host edits
        //     live in SSHKnownHostsManager, a user-initiated path.
        //   • /var/db/mds/messages — this is the Spotlight metadata server's
        //     state directory, NOT a "Bonjour cache". It is root-owned and
        //     deleting it can corrupt Spotlight indexing.
        //   • ~/Library/Preferences/com.apple.networkextension.cache.plist —
        //     sits under the protected Preferences root; it is a tiny plist and
        //     not worth the risk surface of an explicit carve-out.
        items.append(contentsOf: await scanNetworkServiceProxy())

        return items.sorted { $0.size > $1.size }
    }

    // MARK: - Network Service Proxy Cache

    private func scanNetworkServiceProxy() async -> [CleanupItem] {
        let cacheDir = URL.libraryDirectory.appending(path: "Caches/com.apple.networkserviceproxy")
        guard let item = await scanCacheDirectory(
            at: cacheDir,
            moduleName: "Network Service Proxy Cache",
            threshold: 1024
        ) else { return [] }
        return [item]
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        await cleanItems(items, dryRun: dryRun) { item, _ in
            try CleanupFileRemover.permanent(item.path, module: item.module)
        }
    }
}

// MARK: - WiFi Network Management

typealias WiFiCommandRunner = @Sendable (
    _ executable: String,
    _ arguments: [String],
    _ timeout: TimeInterval
) async throws -> ProcessResult

struct WiFiNetworkManager {
    static let listingTimeout: TimeInterval = 30
    static let removalTimeout: TimeInterval = 30

    /// Get list of saved WiFi networks on the primary interface.
    /// Delegates to `savedNetworks(interface:)` so the bounded subprocess and
    /// parsing behavior have a single implementation. Callers that need the
    /// connected marker pass their already-captured SSID explicitly; count and
    /// lookup callers avoid an otherwise-unused CoreWLAN query.
    static func savedNetworks(
        currentSSID: String? = nil
    ) async -> [SavedWiFiNetwork] {
        let interface = await WiFiInterfaceManager.primaryInterface()
        return await savedNetworks(interface: interface, currentSSID: currentSSID)
    }

    /// Get list of saved WiFi networks for a specific interface
    static func savedNetworks(
        interface: String,
        currentSSID: String?,
        commandRunner: WiFiCommandRunner = { executable, arguments, timeout in
            try await ProcessRunner.run(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        }
    ) async -> [SavedWiFiNetwork] {
        guard let result = try? await commandRunner(
            "/usr/sbin/networksetup",
            ["-listpreferredwirelessnetworks", interface],
            Self.listingTimeout
        ), result.didSucceed, result.outputWasValidUTF8 else {
            return []
        }

        var networks: [SavedWiFiNetwork] = result.output
            .split(separator: "\n")
            .dropFirst()
            .compactMap { line in
                let name = line.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }
                return SavedWiFiNetwork(
                    ssid: name,
                    isCurrentlyConnected: false
                )
            }

        if let currentSSID,
           let currentIndex = networks.firstIndex(where: { $0.ssid == currentSSID }) {
            networks[currentIndex].isCurrentlyConnected = true
        }

        return networks
    }

    /// Get currently connected WiFi SSID
    static func getCurrentSSID() -> String? {
        guard let interface = CWWiFiClient.shared().interface() else { return nil }
        return interface.ssid()
    }

    /// Get current connection security type
    static func getCurrentSecurityType() -> String? {
        guard let interface = CWWiFiClient.shared().interface() else { return nil }
        return securityTypeString(interface.security())
    }

    /// Convert CWSecurity enum to readable string
    private static func securityTypeString(_ security: CWSecurity) -> String {
        switch security {
        case .none: return "None"
        case .WEP: return "WEP"
        case .wpaPersonal: return "WPA Personal"
        case .wpaPersonalMixed: return "WPA Personal Mixed"
        case .wpa2Personal: return "WPA2 Personal"
        case .personal: return "Personal"
        case .dynamicWEP: return "Dynamic WEP"
        case .wpaEnterprise: return "WPA Enterprise"
        case .wpaEnterpriseMixed: return "WPA Enterprise Mixed"
        case .wpa2Enterprise: return "WPA2 Enterprise"
        case .enterprise: return "Enterprise"
        case .wpa3Personal: return "WPA3 Personal"
        case .wpa3Enterprise: return "WPA3 Enterprise"
        case .wpa3Transition: return "WPA3 Transition"
        case .OWE: return "Enhanced Open (OWE)"
        case .oweTransition: return "Enhanced Open Transition"
        case .unknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }

    /// Remove a saved WiFi network
    static func removeNetwork(_ ssid: String) async throws {
        let interface = await WiFiInterfaceManager.primaryInterface()
        try await removeNetwork(ssid, interface: interface)
    }

    /// Remove a saved WiFi network from a specific interface
    static func removeNetwork(
        _ ssid: String,
        interface: String,
        commandRunner: WiFiCommandRunner = { executable, arguments, timeout in
            try await ProcessRunner.run(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        }
    ) async throws {
        do {
            try await commandRunner(
                "/usr/sbin/networksetup",
                ["-removepreferredwirelessnetwork", interface, ssid],
                Self.removalTimeout
            ).checkedSuccess()
        } catch {
            throw NetworkError.removeNetworkFailed(ssid)
        }
    }

    /// Remove multiple networks
    static func removeNetworks(_ ssids: [String]) async throws {
        for ssid in ssids {
            try await removeNetwork(ssid)
        }
    }

    /// Remove all saved networks except current and protected
    static func removeAllExceptCurrent(protectedSSIDs: Set<String> = []) async throws {
        let current = getCurrentSSID()
        let networks = await savedNetworks(currentSSID: current)

        for network in networks {
            if !network.isCurrentlyConnected && !protectedSSIDs.contains(network.ssid) {
                try? await removeNetwork(network.ssid)
            }
        }
    }
}

struct SavedWiFiNetwork: Identifiable {
    let id = UUID()
    let ssid: String
    var isCurrentlyConnected: Bool
}

enum NetworkError: LocalizedError {
    case removeNetworkFailed(String)

    var errorDescription: String? {
        switch self {
        case .removeNetworkFailed(let ssid):
            return "Failed to remove network: \(ssid)"
        }
    }
}

// MARK: - SSH Known Hosts Management

enum SSHKnownHostsError: Error {
    /// The advisory lock guarding the read-modify-write could not be acquired.
    case lockFailed
}

struct SSHKnownHostsManager {
    private static var knownHostsPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/known_hosts")
    }

    /// Get list of known hosts
    static func getKnownHosts() -> [SSHKnownHost] {
        guard let content = try? String(contentsOf: knownHostsPath, encoding: .utf8) else {
            return []
        }

        var hosts: [SSHKnownHost] = []

        for line in content.split(separator: "\n") {
            let lineStr = String(line)
            guard !lineStr.isEmpty, !lineStr.hasPrefix("#") else { continue }

            // Format: hostname algorithm key [comment]
            let parts = lineStr.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2 else { continue }

            let hostPart = String(parts[0])
            let algorithm = String(parts[1])

            // Handle hashed hosts
            let displayHost: String
            if hostPart.hasPrefix("|1|") {
                displayHost = "[hashed]"
            } else {
                displayHost = hostPart.split(separator: ",").first.map(String.init) ?? hostPart
            }

            hosts.append(SSHKnownHost(
                host: displayHost,
                rawLine: lineStr,
                algorithm: algorithm,
                isHashed: hostPart.hasPrefix("|1|")
            ))
        }

        return hosts
    }

    /// Remove a specific host entry.
    ///
    /// Serializes the whole read-modify-write behind an advisory lock (`flock`)
    /// so concurrent MacSweep removals can't lose each other's edits, and
    /// re-reads `known_hosts` *after* acquiring the lock so a host key appended
    /// by `ssh` (trust-on-first-use) just before we rewrite is preserved. The
    /// lock lives on a dedicated file, not `known_hosts` itself: the atomic
    /// write below replaces the file's inode, which would strand a lock held on
    /// the original.
    static func removeHost(_ host: SSHKnownHost) throws {
        try removeHost(host, from: knownHostsPath)
    }

    /// Path-injectable core of `removeHost`, exposed for testing.
    static func removeHost(_ host: SSHKnownHost, from path: URL) throws {
        // Nothing to remove if the file doesn't exist yet — don't create a lock
        // file or throw in that case.
        guard FileManager.default.fileExists(atPath: path.path) else { return }

        let lockPath = path.deletingLastPathComponent().appending(path: ".known_hosts.macsweep.lock")
        let fd = open(lockPath.path, O_CREAT | O_RDWR, 0o600)
        guard fd != -1 else { throw SSHKnownHostsError.lockFailed }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw SSHKnownHostsError.lockFailed }
        defer { flock(fd, LOCK_UN) }

        // Read the freshest contents now that we hold the lock.
        guard let content = try? String(contentsOf: path, encoding: .utf8) else {
            return
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let filteredLines = lines.filter { String($0) != host.rawLine }
        let newContent = filteredLines.joined(separator: "\n")

        try newContent.write(to: path, atomically: true, encoding: .utf8)
    }

    /// Clear all known hosts (creates backup)
    static func clearAll() throws {
        let backupPath = knownHostsPath.deletingLastPathComponent().appending(path: "known_hosts.backup")

        // Create backup
        try? FileManager.default.removeItem(at: backupPath)
        try FileManager.default.copyItem(at: knownHostsPath, to: backupPath)

        // Clear file
        try "".write(to: knownHostsPath, atomically: true, encoding: .utf8)
    }
}

struct SSHKnownHost: Identifiable {
    let id = UUID()
    let host: String
    let rawLine: String
    let algorithm: String
    let isHashed: Bool
}

// MARK: - DNS Cache Manager

typealias DNSCacheCommandRunner =
    @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ timeout: TimeInterval
    ) async throws -> ProcessResult

struct DNSCacheManager {
    /// Check if we can flush DNS
    static var canFlush: Bool {
        return FileManager.default.fileExists(atPath: "/usr/bin/dscacheutil")
    }

    /// Flush the DNS cache
    /// Note: Full DNS flush (mDNSResponder restart) requires admin privileges.
    /// This method performs a partial flush that doesn't require elevation.
    static func flush(
        commandRunner: DNSCacheCommandRunner = { executable, arguments, timeout in
            try await ProcessRunner.run(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        }
    ) async throws {
        do {
            try await commandRunner(
                "/usr/bin/dscacheutil",
                ["-flushcache"],
                30
            ).checkedSuccess()
        } catch {
            throw DNSError.flushFailed
        }

        // Note: killall -HUP mDNSResponder requires root/admin privileges
        // and cannot be done from a sandboxed app without user elevation.
        // The dscacheutil flush above handles most DNS cache clearing needs.
    }

    /// Flush DNS with admin privileges (prompts user).
    ///
    /// This is the single privilege-escalation site in the app. It is routed
    /// through `PrivilegedRunner` — the one named, audited escalation helper —
    /// rather than an inline `osascript` call or `ProcessRunner`, because it runs
    /// a shell script as root. The command string is a hard-coded constant; no
    /// untrusted input is interpolated. Note: may not work in sandboxed apps.
    static func flushWithAdmin() async throws {
        do {
            try await PrivilegedRunner.runShellScriptAsAdmin(
                "dscacheutil -flushcache; killall -HUP mDNSResponder")
        } catch {
            throw DNSError.flushFailed
        }
    }
}

enum DNSError: LocalizedError {
    case flushFailed

    var errorDescription: String? {
        switch self {
        case .flushFailed:
            return "Failed to flush DNS cache"
        }
    }
}

// MARK: - WiFi Interface Manager

struct WiFiInterfaceManager {
    static let listingTimeout: TimeInterval = 10

    /// Get all available WiFi interfaces via bounded `networksetup` (no raw `Process()`).
    static func availableInterfaces(
        commandRunner: WiFiCommandRunner = { executable, arguments, timeout in
            try await ProcessRunner.run(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        }
    ) async -> [String] {
        guard let result = try? await commandRunner(
            "/usr/sbin/networksetup",
            ["-listallhardwareports"],
            Self.listingTimeout
        ), result.didSucceed, result.outputWasValidUTF8 else {
            return ["en0"]
        }

        let interfaces = parseWiFiInterfaces(from: result.output)
        return interfaces.isEmpty ? ["en0"] : interfaces
    }

    /// Pure parser for `networksetup -listallhardwareports` Wi-Fi device lines.
    static func parseWiFiInterfaces(from output: String) -> [String] {
        var interfaces: [String] = []
        var isWiFi = false

        for line in output.split(separator: "\n") {
            let lineStr = String(line)
            if lineStr.contains("Wi-Fi") || lineStr.contains("AirPort") {
                isWiFi = true
            } else if isWiFi && lineStr.hasPrefix("Device:") {
                let device = lineStr
                    .replacingOccurrences(of: "Device: ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !device.isEmpty {
                    interfaces.append(device)
                }
                isWiFi = false
            } else if lineStr.hasPrefix("Hardware Port:") {
                isWiFi = false
            }
        }
        return interfaces
    }

    /// Get the primary WiFi interface
    static func primaryInterface(
        commandRunner: WiFiCommandRunner = { executable, arguments, timeout in
            try await ProcessRunner.run(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        }
    ) async -> String {
        if let name = CWWiFiClient.shared().interface()?.interfaceName, !name.isEmpty {
            return name
        }
        return (await availableInterfaces(commandRunner: commandRunner)).first ?? "en0"
    }

    /// Check if WiFi is enabled
    static var isWiFiEnabled: Bool {
        guard let interface = CWWiFiClient.shared().interface() else { return false }
        return interface.powerOn()
    }

    /// Get current WiFi info
    static func currentNetworkInfo() -> (ssid: String?, bssid: String?, rssi: Int?) {
        guard let interface = CWWiFiClient.shared().interface() else {
            return (nil, nil, nil)
        }
        return (interface.ssid(), interface.bssid(), interface.rssiValue())
    }
}

// MARK: - Network Cleanup Summary

struct NetworkCleanupSummary {
    var savedNetworks: Int = 0
    var knownHosts: Int = 0
    var cacheSize: Int64 = 0
    var canFlushDNS: Bool = true

    var formattedCacheSize: String {
        cacheSize.formattedFileSize
    }

    static func current() async -> NetworkCleanupSummary {
        var summary = NetworkCleanupSummary()

        // Count saved WiFi networks
        summary.savedNetworks = await WiFiNetworkManager.savedNetworks().count

        // Count SSH known hosts
        summary.knownHosts = SSHKnownHostsManager.getKnownHosts().count

        // Calculate total cache size
        let networkCachePaths: [URL] = [
            URL.libraryDirectory.appending(path: "Caches/com.apple.networkserviceproxy"),
            URL.libraryDirectory.appending(path: "Preferences/com.apple.networkextension.cache.plist")
        ]

        for path in networkCachePaths {
            if FileManager.default.fileExists(atPath: path.path) {
                let size = (try? await DiskAnalyzer.size(of: path)) ?? 0
                summary.cacheSize += size
            }
        }

        return summary
    }
}

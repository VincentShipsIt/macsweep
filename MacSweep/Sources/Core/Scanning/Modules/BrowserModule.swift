import Foundation
import AppKit
import Darwin

/// Protocol for browser-specific cleanup modules
protocol BrowserModule: ScanModule {
    var browserName: String { get }
    var bundleID: String { get }
    var basePath: URL { get }

    var isInstalled: Bool { get }
    var isRunning: Bool { get }

    /// Safe to delete - auto regenerated
    var cachePaths: [URL] { get }

    /// Low risk - background scripts
    var serviceWorkerPaths: [URL] { get }

    /// Medium risk - site data, may cause logouts
    var localStoragePaths: [URL] { get }

    /// High risk - will log user out of all sites (opt-in only)
    var cookiePaths: [URL] { get }

    /// Critical risk - permanent history deletion (opt-in only)
    var historyPaths: [URL] { get }
}

/// Browser module IDs share this namespace, so history classification cannot
/// drift when another browser module is added.
enum BrowserModuleID {
    private static let prefix = "browser-"

    static func matches(_ moduleID: String) -> Bool {
        moduleID.hasPrefix(prefix)
    }
}

extension BrowserModule {
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: basePath.path)
    }

    var isRunning: Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps.contains { $0.bundleIdentifier == bundleID }
    }

    // Default empty implementations for opt-in paths
    var cookiePaths: [URL] { [] }
    var historyPaths: [URL] { [] }

    /// Build a `CleanupItem` for a browser data directory if it exists and is
    /// larger than 1KB. Shared by every browser module's `scan()` — the previous
    /// per-browser copies had drifted so only Chrome computed `lastModified`,
    /// leaving the stale-data hint rendered for exactly one browser. Now a thin
    /// wrapper over the shared `scanCacheDirectory` idiom.
    func scanPath(_ url: URL, category: String) async -> CleanupItem? {
        await scanCacheDirectory(
            at: url,
            moduleName: "\(browserName) \(category)",
            threshold: 1024  // Skip tiny items
        )
    }

    /// Get risk level for a given path
    func riskLevel(for url: URL) -> BrowserDataRiskLevel {
        let path = url.path
        if cachePaths.contains(where: { path.hasPrefix($0.path) }) {
            return .none
        }
        if serviceWorkerPaths.contains(where: { path.hasPrefix($0.path) }) {
            return .low
        }
        if localStoragePaths.contains(where: { path.hasPrefix($0.path) }) {
            return .medium
        }
        if cookiePaths.contains(where: { path.hasPrefix($0.path) }) {
            return .high
        }
        if historyPaths.contains(where: { path.hasPrefix($0.path) }) {
            return .critical
        }
        return .none
    }

    func cleanBrowserItems(_ items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        // Filter to this module BEFORE the running-browser guard: a running
        // browser must not veto a cleanup that contains none of its items.
        let moduleItems = items.filter { $0.module == id }
        guard !moduleItems.isEmpty else {
            return CleanupResult(itemsProcessed: 0, bytesFreed: 0, errors: [])
        }
        if isRunning && !dryRun {
            throw BrowserCleanupError.browserRunning(browserName)
        }

        return await cleanItems(moduleItems, dryRun: dryRun) { item, _ in
            try BrowserCacheRemover.removeContents(at: item.path)
        }
    }
}

/// Removes browser-cache contents without ever resolving a symbolic link.
///
/// The walk is anchored to directory descriptors instead of path-based
/// `FileManager` recursion. Every component leading to the cache root is opened
/// with `O_NOFOLLOW`; encountering a symlink there rejects the whole item. A
/// symlink that is itself the cache root is rejected as a stale replacement; a
/// symlink below a real cache root is unlinked as a node with `unlinkat`, and no
/// symlink target is ever opened.
private enum BrowserCacheRemover {
    static func removeContents(at url: URL) throws {
        let path = url.standardized.path
        guard url.isFileURL, path.hasPrefix("/") else {
            throw BrowserCacheRemovalError.invalidPath(path)
        }

        let components = (path as NSString).pathComponents.filter { $0 != "/" }
        guard let rootName = components.last else {
            throw BrowserCacheRemovalError.invalidPath(path)
        }

        var parentFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else {
            throw BrowserCacheRemovalError.systemCall(
                operation: "open",
                path: "/",
                code: errno
            )
        }
        defer { close(parentFD) }

        var traversedPath = ""
        for component in components.dropLast() {
            traversedPath += "/\(component)"
            let nextFD = try openDirectoryComponent(
                named: component,
                at: parentFD,
                displayPath: traversedPath
            )
            close(parentFD)
            parentFD = nextFD
        }

        var rootInfo = stat()
        let statResult = rootName.withCString {
            fstatat(parentFD, $0, &rootInfo, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0 else {
            throw BrowserCacheRemovalError.systemCall(
                operation: "fstatat",
                path: path,
                code: errno
            )
        }

        let rootType = rootInfo.st_mode & mode_t(S_IFMT)
        if rootType == mode_t(S_IFLNK) {
            // Explicit root policy: reject and preserve the link. A cache that
            // was a real directory when scanned may have been replaced by a
            // symlink before cleanup; treating an unlink as full success would
            // credit the stale directory size even though only the link node was
            // affected. The caller records this as a zero-byte partial failure.
            throw BrowserCacheRemovalError.symbolicLinkRoot(path)
        }
        guard rootType == mode_t(S_IFDIR) else {
            throw BrowserCacheRemovalError.notDirectory(path)
        }

        let rootFD = rootName.withCString {
            openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootFD >= 0 else {
            throw BrowserCacheRemovalError.systemCall(
                operation: "openat",
                path: path,
                code: errno
            )
        }
        defer { close(rootFD) }

        try removeChildren(from: rootFD, displayPath: path)
    }

    private static func openDirectoryComponent(
        named name: String,
        at parentFD: Int32,
        displayPath: String
    ) throws -> Int32 {
        var info = stat()
        let statResult = name.withCString {
            fstatat(parentFD, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0 else {
            throw BrowserCacheRemovalError.systemCall(
                operation: "fstatat",
                path: displayPath,
                code: errno
            )
        }

        let type = info.st_mode & mode_t(S_IFMT)
        guard type != mode_t(S_IFLNK) else {
            throw BrowserCacheRemovalError.symbolicLinkComponent(displayPath)
        }
        guard type == mode_t(S_IFDIR) else {
            throw BrowserCacheRemovalError.notDirectory(displayPath)
        }

        let descriptor = name.withCString {
            openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw BrowserCacheRemovalError.systemCall(
                operation: "openat",
                path: displayPath,
                code: errno
            )
        }
        return descriptor
    }

    private static func removeChildren(from directoryFD: Int32, displayPath: String) throws {
        // Give fdopendir its own descriptor; closedir takes ownership of it.
        let streamFD = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard streamFD >= 0 else {
            throw BrowserCacheRemovalError.systemCall(
                operation: "openat",
                path: displayPath,
                code: errno
            )
        }
        guard let directory = fdopendir(streamFD) else {
            let code = errno
            close(streamFD)
            throw BrowserCacheRemovalError.systemCall(
                operation: "fdopendir",
                path: displayPath,
                code: code
            )
        }
        defer { closedir(directory) }

        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                let code = errno
                if code != 0 {
                    throw BrowserCacheRemovalError.systemCall(
                        operation: "readdir",
                        path: displayPath,
                        code: code
                    )
                }
                break
            }

            var nameBuffer = entry.pointee.d_name
            let capacity = MemoryLayout.size(ofValue: nameBuffer)
            try withUnsafePointer(to: &nameBuffer) { buffer in
                try buffer.withMemoryRebound(to: CChar.self, capacity: capacity) { name in
                    guard strcmp(name, ".") != 0, strcmp(name, "..") != 0 else { return }
                    try removeEntry(named: name, at: directoryFD, displayParent: displayPath)
                }
            }
        }
    }

    private static func removeEntry(
        named name: UnsafePointer<CChar>,
        at parentFD: Int32,
        displayParent: String
    ) throws {
        let displayName = String(validatingUTF8: name) ?? "<non-UTF-8 entry>"
        let displayPath = displayParent + "/" + displayName

        var info = stat()
        guard fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            if code == ENOENT { return }
            throw BrowserCacheRemovalError.systemCall(
                operation: "fstatat",
                path: displayPath,
                code: code
            )
        }

        let type = info.st_mode & mode_t(S_IFMT)
        if type == mode_t(S_IFDIR) {
            let childFD = openat(
                parentFD,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard childFD >= 0 else {
                let code = errno
                if code == ENOENT { return }
                throw BrowserCacheRemovalError.systemCall(
                    operation: "openat",
                    path: displayPath,
                    code: code
                )
            }

            do {
                try removeChildren(from: childFD, displayPath: displayPath)
                close(childFD)
            } catch {
                close(childFD)
                throw error
            }

            guard unlinkat(parentFD, name, AT_REMOVEDIR) == 0 else {
                let code = errno
                if code == ENOENT { return }
                throw BrowserCacheRemovalError.systemCall(
                    operation: "unlinkat",
                    path: displayPath,
                    code: code
                )
            }
            return
        }

        // Files and special nodes are unlinked directly. For symlinks this is
        // the explicit nested-node policy: unlink the link, never open it.
        guard unlinkat(parentFD, name, 0) == 0 else {
            let code = errno
            if code == ENOENT { return }
            throw BrowserCacheRemovalError.systemCall(
                operation: "unlinkat",
                path: displayPath,
                code: code
            )
        }
    }

}

private enum BrowserCacheRemovalError: LocalizedError {
    case invalidPath(String)
    case symbolicLinkRoot(String)
    case symbolicLinkComponent(String)
    case notDirectory(String)
    case systemCall(operation: String, path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            return "Refused invalid browser cache path: \(path)"
        case .symbolicLinkRoot(let path):
            return "Refused browser cache root because it is a symbolic link: \(path)"
        case .symbolicLinkComponent(let path):
            return "Refused browser cache path with a symbolic-link component: \(path)"
        case .notDirectory(let path):
            return "Browser cache path component is not a directory: \(path)"
        case .systemCall(let operation, let path, let code):
            return "\(operation) failed for \(path): \(String(cString: strerror(code)))"
        }
    }
}

// MARK: - Browser Cleanup Error

enum BrowserCleanupError: LocalizedError {
    case browserRunning(String)
    case noAccess(String)
    case fullDiskAccessRequired

    var errorDescription: String? {
        switch self {
        case .browserRunning(let name):
            return "Please quit \(name) before cleaning"
        case .noAccess(let path):
            return "Cannot access \(path). Full Disk Access may be required."
        case .fullDiskAccessRequired:
            return "Full Disk Access is required to clean Safari data"
        }
    }
}

// MARK: - Data Risk Level

enum BrowserDataRiskLevel: Int, Comparable {
    case none = 0      // Cache - auto regenerated
    case low = 1       // Service Workers - background scripts
    case medium = 2    // LocalStorage - site data
    case high = 3      // Cookies - session data
    case critical = 4  // History - browsing history

    static func < (lhs: BrowserDataRiskLevel, rhs: BrowserDataRiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var description: String {
        switch self {
        case .none: return "Safe to delete"
        case .low: return "Low risk"
        case .medium: return "May log you out of websites"
        case .high: return "Will log you out of all websites"
        case .critical: return "Permanently deletes browsing history"
        }
    }

    var warningMessage: String? {
        switch self {
        case .none, .low:
            return nil
        case .medium:
            return "Deleting LocalStorage may log you out of some websites and reset site preferences."
        case .high:
            return "Deleting cookies will log you out of ALL websites. You will need to sign in again."
        case .critical:
            return "Deleting browsing history is permanent and cannot be undone."
        }
    }
}

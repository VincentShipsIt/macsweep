import Foundation
import AppKit

// MARK: - Firefox Module

struct FirefoxModule: BrowserModule {
    let id = "browser-firefox"
    let name = "Firefox"
    let description = "Firefox caches and offline storage"
    let icon = "flame"
    let browserName = "Firefox"
    let bundleID = "org.mozilla.firefox"

    var basePath: URL {
        URL.libraryDirectory.appending(path: "Application Support/Firefox")
    }

    var cachePaths: [URL] {
        profilePaths.flatMap { profile in
            [
                profile.appending(path: "cache2"),
                profile.appending(path: "shader-cache"),
                profile.appending(path: "startupCache"),
            ]
        }
    }

    var serviceWorkerPaths: [URL] {
        profilePaths.map { $0.appending(path: "storage/default") }
    }

    var localStoragePaths: [URL] {
        profilePaths.map { $0.appending(path: "storage/default") }
    }

    var cookiePaths: [URL] {
        profilePaths.map { $0.appending(path: "cookies.sqlite") }
    }

    var historyPaths: [URL] {
        profilePaths.map { $0.appending(path: "places.sqlite") }
    }

    /// Get all Firefox profile directories
    private var profilePaths: [URL] {
        let profilesDir = basePath.appending(path: "Profiles")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: profilesDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        return contents.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    func scan() async throws -> [CleanupItem] {
        guard isInstalled else { return [] }

        var items: [CleanupItem] = []

        for cachePath in cachePaths {
            if let item = await scanPath(cachePath, category: "Cache") {
                items.append(item)
            }
        }

        return items
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        try await cleanBrowserItems(items, dryRun: dryRun)
    }
}


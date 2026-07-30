import Foundation
import AppKit

// MARK: - Safari Module

struct SafariModule: BrowserModule {
    let id = "browser-safari"
    let name = "Safari"
    let description = "Safari caches and website data (requires Full Disk Access)"
    let icon = "safari"
    let browserName = "Safari"
    let bundleID = "com.apple.Safari"

    var basePath: URL {
        URL.libraryDirectory.appending(path: "Safari")
    }

    var cachePaths: [URL] {
        // LocalStorage and Databases are NOT regenerable cache: clearing them logs
        // the user out of sites and drops saved state. They belong in
        // localStoragePaths (medium-risk, opt-in), not here — listing them as cache
        // makes riskLevel() report .none and scan() surface them as safe-to-delete.
        [
            URL.libraryDirectory.appending(path: "Caches/com.apple.Safari"),
            URL.libraryDirectory.appending(path: "Caches/com.apple.Safari.SafeBrowsing"),
        ]
    }

    var serviceWorkerPaths: [URL] {
        [basePath.appending(path: "ServiceWorkers")]
    }

    var localStoragePaths: [URL] {
        [
            basePath.appending(path: "LocalStorage"),
            basePath.appending(path: "Databases"),
        ]
    }

    var cookiePaths: [URL] {
        [URL.libraryDirectory.appending(path: "Cookies/Cookies.binarycookies")]
    }

    var historyPaths: [URL] {
        [basePath.appending(path: "History.db")]
    }

    /// Check if we have Full Disk Access
    var hasFullDiskAccess: Bool {
        // Try to read a protected Safari file
        let testPath = basePath.appending(path: "History.db")
        return FileManager.default.isReadableFile(atPath: testPath.path)
    }

    func scan() async throws -> [CleanupItem] {
        guard isInstalled else { return [] }

        var items: [CleanupItem] = []

        for cachePath in cachePaths {
            if let item = await scanPath(cachePath, category: "Cache") {
                items.append(item)
            }
        }

        for swPath in serviceWorkerPaths {
            if let item = await scanPath(swPath, category: "Service Workers") {
                items.append(item)
            }
        }

        return items
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        try await cleanBrowserItems(items, dryRun: dryRun)
    }
}


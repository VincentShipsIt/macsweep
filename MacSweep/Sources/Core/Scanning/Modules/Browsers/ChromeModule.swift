import Foundation
import AppKit

// MARK: - Chrome Module

struct ChromeModule: BrowserModule {
    let id = "browser-chrome"
    let name = "Google Chrome"
    let description = "Chrome caches, service workers, and browsing data"
    let icon = "globe"
    let browserName = "Chrome"
    let bundleID = "com.google.Chrome"

    var basePath: URL {
        URL.libraryDirectory.appending(path: "Application Support/Google/Chrome")
    }

    var cachePaths: [URL] {
        var paths: [URL] = []
        for profile in profiles {
            paths.append(contentsOf: [
                basePath.appending(path: "\(profile)/Cache"),
                basePath.appending(path: "\(profile)/Code Cache"),
                basePath.appending(path: "\(profile)/GPUCache"),
                basePath.appending(path: "\(profile)/ShaderCache"),
            ])
        }
        paths.append(basePath.appending(path: "ShaderCache"))
        return paths
    }

    var serviceWorkerPaths: [URL] {
        profiles.map { basePath.appending(path: "\($0)/Service Worker") }
    }

    var localStoragePaths: [URL] {
        profiles.map { basePath.appending(path: "\($0)/Local Storage") }
    }

    var cookiePaths: [URL] {
        profiles.map { basePath.appending(path: "\($0)/Cookies") }
    }

    var historyPaths: [URL] {
        profiles.map { basePath.appending(path: "\($0)/History") }
    }

    /// Detect all Chrome profiles (Default, Profile 1, Profile 2, etc.)
    private var profiles: [String] {
        var found: [String] = ["Default"]
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: basePath.path) else {
            return found
        }
        for item in contents {
            if item.hasPrefix("Profile ") {
                found.append(item)
            }
        }
        return found
    }

    func scan() async throws -> [CleanupItem] {
        guard isInstalled else { return [] }

        var items: [CleanupItem] = []

        // Scan cache paths
        for cachePath in cachePaths {
            if let item = await scanPath(cachePath, category: "Cache") {
                items.append(item)
            }
        }

        // Scan service workers
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


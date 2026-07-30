import Foundation
import AppKit

// MARK: - Brave Module

struct BraveModule: BrowserModule {
    let id = "browser-brave"
    let name = "Brave"
    let description = "Brave browser caches and service workers"
    let icon = "shield"
    let browserName = "Brave"
    let bundleID = "com.brave.Browser"

    var basePath: URL {
        URL.libraryDirectory.appending(path: "Application Support/BraveSoftware/Brave-Browser")
    }

    var cachePaths: [URL] {
        var paths: [URL] = []
        for profile in profiles {
            paths.append(contentsOf: [
                basePath.appending(path: "\(profile)/Cache"),
                basePath.appending(path: "\(profile)/Code Cache"),
                basePath.appending(path: "\(profile)/GPUCache"),
            ])
        }
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

    private var profiles: [String] {
        var found: [String] = ["Default"]
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: basePath.path) else {
            return found
        }
        for item in contents where item.hasPrefix("Profile ") {
            found.append(item)
        }
        return found
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


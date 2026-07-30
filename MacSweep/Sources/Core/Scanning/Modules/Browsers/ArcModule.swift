import Foundation
import AppKit

// MARK: - Arc Module

struct ArcModule: BrowserModule {
    let id = "browser-arc"
    let name = "Arc"
    let description = "Arc browser caches and data"
    let icon = "circle.hexagongrid"
    let browserName = "Arc"
    let bundleID = "company.thebrowser.Browser"

    var basePath: URL {
        URL.libraryDirectory.appending(path: "Application Support/Arc")
    }

    private var userDataPath: URL {
        basePath.appending(path: "User Data")
    }

    var cachePaths: [URL] {
        var paths: [URL] = []
        for profile in profiles {
            paths.append(contentsOf: [
                userDataPath.appending(path: "\(profile)/Cache"),
                userDataPath.appending(path: "\(profile)/Code Cache"),
                userDataPath.appending(path: "\(profile)/GPUCache"),
            ])
        }
        paths.append(userDataPath.appending(path: "ShaderCache"))
        return paths
    }

    var serviceWorkerPaths: [URL] {
        profiles.map { userDataPath.appending(path: "\($0)/Service Worker") }
    }

    var localStoragePaths: [URL] {
        profiles.map { userDataPath.appending(path: "\($0)/Local Storage") }
    }

    var cookiePaths: [URL] {
        profiles.map { userDataPath.appending(path: "\($0)/Cookies") }
    }

    var historyPaths: [URL] {
        profiles.map { userDataPath.appending(path: "\($0)/History") }
    }

    /// Detect Arc profiles
    private var profiles: [String] {
        var found: [String] = ["Default"]
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: userDataPath.path) else {
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


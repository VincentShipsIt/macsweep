import Foundation
import Testing
@testable import MacSweepCore

final class ServiceWorkerModuleTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSweepSW-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func cleanTrashesContentsOfServiceWorkerDirectory() async throws {
        let swDir = dir.appendingPathComponent("Service Worker")
        try FileManager.default.createDirectory(at: swDir, withIntermediateDirectories: true)
        let child = swDir.appendingPathComponent("CacheStorage")
        try Data("blob".utf8).write(to: child)

        let module = ServiceWorkerModule()
        let item = CleanupItem(
            id: UUID(),
            path: swDir,
            size: 4,
            type: .directory,
            module: module.id,
            moduleName: "Custom App Service Worker"
        )

        let result = try await module.clean(items: [item], dryRun: false)
        #expect(result.errors.isEmpty)
        #expect(result.itemsProcessed == 1)
        #expect(FileManager.default.fileExists(atPath: swDir.path))
        #expect(!FileManager.default.fileExists(atPath: child.path))
    }

    @Test func dryRunLeavesContents() async throws {
        let swDir = dir.appendingPathComponent("Service Worker Dry")
        try FileManager.default.createDirectory(at: swDir, withIntermediateDirectories: true)
        let child = swDir.appendingPathComponent("ScriptCache")
        try Data("x".utf8).write(to: child)

        let module = ServiceWorkerModule()
        let item = CleanupItem(
            id: UUID(),
            path: swDir,
            size: 1,
            type: .directory,
            module: module.id,
            moduleName: "Custom App Service Worker"
        )

        let result = try await module.clean(items: [item], dryRun: true)
        #expect(result.itemsProcessed == 1)
        #expect(FileManager.default.fileExists(atPath: child.path))
    }
}

import Foundation
import Testing
@testable import MacSweepCore

final class PackageManagerModuleTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSweepPkgMgr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func cleanRoutesThroughRemoverAndTrashesCacheFile() async throws {
        let cache = dir.appendingPathComponent("npm-cache.bin")
        try Data("stale".utf8).write(to: cache)

        let module = PackageManagerModule()
        let item = CleanupItem(
            id: UUID(),
            path: cache,
            size: 5,
            type: .file,
            module: module.id,
            moduleName: "npm Cache"
        )

        let result = try await module.clean(items: [item], dryRun: false)
        #expect(result.errors.isEmpty)
        #expect(result.itemsProcessed == 1)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func missingFileAccumulatesError() async throws {
        let missing = dir.appendingPathComponent("gone.bin")
        let module = PackageManagerModule()
        let item = CleanupItem(
            id: UUID(),
            path: missing,
            size: 1,
            type: .file,
            module: module.id,
            moduleName: "pip Cache"
        )

        let result = try await module.clean(items: [item], dryRun: false)
        #expect(!result.errors.isEmpty)
        #expect(result.itemsProcessed == 0)
    }

    @Test func dryRunDoesNotDelete() async throws {
        let cache = dir.appendingPathComponent("keep.bin")
        try Data("keep".utf8).write(to: cache)
        let module = PackageManagerModule()
        let item = CleanupItem(
            id: UUID(),
            path: cache,
            size: 4,
            type: .file,
            module: module.id,
            moduleName: "Yarn Cache"
        )

        let result = try await module.clean(items: [item], dryRun: true)
        #expect(result.itemsProcessed == 1)
        #expect(result.bytesFreed == 4)
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }
}

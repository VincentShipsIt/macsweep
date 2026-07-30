import Testing
import Foundation
@testable import MacSweepCore

struct ScanEngineTests {
    actor CleanupRecorder {
        private var calls: [String: [CleanupItem]] = [:]
        private var order: [String] = []

        func record(moduleID: String, items: [CleanupItem]) {
            calls[moduleID] = items
            order.append(moduleID)
        }

        func items(for moduleID: String) -> [CleanupItem] {
            calls[moduleID] ?? []
        }

        func cleanupOrder() -> [String] {
            order
        }
    }

    struct TestModule: ScanModule {
        let id: String
        let name: String
        let description: String
        let icon: String = "testtube.2"
        let recorder: CleanupRecorder

        func scan() async throws -> [CleanupItem] { [] }

        func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
            await recorder.record(moduleID: id, items: items)
            return CleanupResult(
                itemsProcessed: items.count,
                bytesFreed: items.reduce(0) { $0 + $1.size }
            )
        }
    }

    struct GrowingTestModule: ScanModule {
        let id: String
        let name: String
        let description: String
        let icon: String = "testtube.2"
        let recorder: CleanupRecorder
        let targetToGrow: URL

        func scan() async throws -> [CleanupItem] { [] }

        func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
            await recorder.record(moduleID: id, items: items)
            if !dryRun {
                try Data(repeating: 0xE7, count: 2_097_152).write(to: targetToGrow)
            }
            return CleanupResult(itemsProcessed: items.count, bytesFreed: 0)
        }
    }

    @Test func cleanDispatchesItemsToOwningModules() async throws {
        let recorder = CleanupRecorder()
        let engine = ScanEngine(modules: [
            TestModule(id: "alpha", name: "Alpha", description: "Alpha", recorder: recorder),
            TestModule(id: "beta", name: "Beta", description: "Beta", recorder: recorder),
        ])

        let tmp = FileManager.default.temporaryDirectory
        let alphaItem = CleanupItem(
            id: UUID(),
            path: tmp.appendingPathComponent("alpha.tmp"),
            size: 512,
            type: .file,
            module: "alpha",
            moduleName: "Alpha"
        )
        let betaItem = CleanupItem(
            id: UUID(),
            path: tmp.appendingPathComponent("beta.tmp"),
            size: 2048,
            type: .file,
            module: "beta",
            moduleName: "Beta"
        )

        let result = try await engine.clean(items: [alphaItem, betaItem], dryRun: true)

        let alphaCalls = await recorder.items(for: "alpha")
        let betaCalls = await recorder.items(for: "beta")

        #expect(alphaCalls == [alphaItem])
        #expect(betaCalls == [betaItem])
        #expect(result.itemsProcessed == 2)
        #expect(result.bytesFreed == 2560)
    }

    @Test func cleanBlocksProtectedPathForStandardModule() async throws {
        let recorder = CleanupRecorder()
        let engine = ScanEngine(modules: [
            TestModule(id: "system-cache", name: "System Cache", description: "System Cache", recorder: recorder),
        ])

        let protectedItem = CleanupItem(
            id: UUID(),
            path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/family-photo.jpg"),
            size: 1024,
            type: .file,
            module: "system-cache",
            moduleName: "System Cache"
        )

        let result = try await engine.clean(items: [protectedItem], dryRun: true)

        let calls = await recorder.items(for: "system-cache")
        #expect(calls.isEmpty)
        #expect(result.itemsProcessed == 0)
        #expect(result.errors.count == 1)
    }

    @Test func cleanAllowsUserManagedPathForSimilarPhotos() async throws {
        let recorder = CleanupRecorder()
        let engine = ScanEngine(modules: [
            TestModule(id: "similar-photos", name: "Similar Photos", description: "Similar Photos", recorder: recorder),
        ])

        let photoItem = CleanupItem(
            id: UUID(),
            path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/similar-shot.jpg"),
            size: 4096,
            type: .file,
            module: "similar-photos",
            moduleName: "Similar to IMG_0001"
        )

        let result = try await engine.clean(items: [photoItem], dryRun: true)

        let calls = await recorder.items(for: "similar-photos")
        #expect(calls == [photoItem])
        #expect(result.itemsProcessed == 1)
        #expect(result.errors.isEmpty)
    }

    @Test func cleanBlocksUserManagedDirectoryForLargeFiles() async throws {
        let recorder = CleanupRecorder()
        let engine = ScanEngine(modules: [
            TestModule(id: "large-files", name: "Large Files", description: "Large Files", recorder: recorder),
        ])

        let projectRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/project-root")
        let projectItem = CleanupItem(
            id: UUID(),
            path: projectRoot,
            size: 5_000_000,
            type: .directory,
            module: "large-files",
            moduleName: "Folder"
        )

        let result = try await engine.clean(items: [projectItem], dryRun: true)

        let calls = await recorder.items(for: "large-files")
        #expect(calls.isEmpty)
        #expect(result.itemsProcessed == 0)
        #expect(result.errors.count == 1)
    }

    @Test func cleanPrioritizesTrashBeforeOtherModules() async throws {
        let recorder = CleanupRecorder()
        let engine = ScanEngine(modules: [
            TestModule(id: "system-cache", name: "System Cache", description: "System Cache", recorder: recorder),
            TestModule(id: "trash-bins", name: "Trash Bins", description: "Trash Bins", recorder: recorder),
        ])

        let tmp = FileManager.default.temporaryDirectory
        let trashItem = CleanupItem(
            id: UUID(),
            path: tmp.appendingPathComponent(".Trash/old-file"),
            size: 512,
            type: .file,
            module: "trash-bins",
            moduleName: "User Trash"
        )
        let cacheItem = CleanupItem(
            id: UUID(),
            path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/example-cache"),
            size: 1024,
            type: .directory,
            module: "system-cache",
            moduleName: "System Cache"
        )

        _ = try await engine.clean(items: [cacheItem, trashItem], dryRun: true)

        let order = await recorder.cleanupOrder()
        #expect(order == ["trash-bins", "system-cache"])
    }

    @Test func cleanThrowsWhenAggregateExceedsHardLimitOnRealDelete() async throws {
        let temp = try TempTestDirectory(prefix: "ScanEngineHardCap")
        try Data(repeating: 0xA5, count: 2_097_152)
            .write(to: temp.appendingPathComponent("huge.cache"))

        let recorder = CleanupRecorder()
        let engine = ScanEngine(modules: [
            TestModule(id: "system-cache", name: "System Cache", description: "System Cache", recorder: recorder),
        ], deletionGuard: DeletionGuard(
            maxTotalSize: 1_048_576,
            confirmationThreshold: 524_288,
            dryRunDefault: true
        ))

        let hugeItem = CleanupItem(
            id: UUID(),
            path: temp.appendingPathComponent("huge.cache"),
            size: 0,
            type: .file,
            module: "system-cache",
            moduleName: "System Cache"
        )

        do {
            _ = try await engine.clean(items: [hugeItem], dryRun: false)
            Issue.record("Expected deletionBlocked to be thrown")
        } catch let error as ScanEngineError {
            guard case .deletionBlocked(let reason) = error else {
                Issue.record("Expected .deletionBlocked, got \(error)")
                return
            }
            #expect(reason.contains("exceeds maximum"))
        } catch {
            Issue.record("Expected ScanEngineError, got \(error)")
        }

        // Nothing should have been dispatched to the module.
        let calls = await recorder.items(for: "system-cache")
        #expect(calls.isEmpty)
    }

    // MARK: - Confirmation threshold (#78)

    private func systemCacheItem(at path: URL, storedSize: Int64 = 0) -> CleanupItem {
        CleanupItem(
            id: UUID(),
            path: path,
            size: storedSize,
            type: .file,
            module: "system-cache",
            moduleName: "System Cache"
        )
    }

    private var lowConfirmationGuard: DeletionGuard {
        DeletionGuard(
            maxTotalSize: 8_388_608,
            confirmationThreshold: 1_048_576,
            dryRunDefault: true
        )
    }

    @Test func cleanRequiresConfirmationOverThresholdWhenNotConfirmed() async throws {
        let temp = try TempTestDirectory(prefix: "ScanEngineConfirmation")
        try Data(repeating: 0x5A, count: 2_097_152)
            .write(to: temp.appendingPathComponent("large.cache"))

        let recorder = CleanupRecorder()
        let engine = ScanEngine(modules: [
            TestModule(id: "system-cache", name: "System Cache", description: "System Cache", recorder: recorder),
        ], deletionGuard: lowConfirmationGuard)

        do {
            _ = try await engine.clean(
                items: [systemCacheItem(at: temp.appendingPathComponent("large.cache"))],
                dryRun: false
            )
            Issue.record("Expected .confirmationRequired to be thrown")
        } catch let error as ScanEngineError {
            guard case .confirmationRequired(let size) = error else {
                Issue.record("Expected .confirmationRequired, got \(error)")
                return
            }
            #expect(size > lowConfirmationGuard.confirmationThreshold)
            #expect(size <= lowConfirmationGuard.maxTotalSize)
        } catch {
            Issue.record("Expected ScanEngineError, got \(error)")
        }

        // The delete must not have been dispatched.
        let calls = await recorder.items(for: "system-cache")
        #expect(calls.isEmpty)
    }

    @Test func cleanProceedsOverThresholdWhenConfirmed() async throws {
        let temp = try TempTestDirectory(prefix: "ScanEngineConfirmed")
        let file = temp.appendingPathComponent("large.cache")
        try Data(repeating: 0xC3, count: 2_097_152).write(to: file)

        let recorder = CleanupRecorder()
        let engine = ScanEngine(modules: [
            TestModule(id: "system-cache", name: "System Cache", description: "System Cache", recorder: recorder),
        ], deletionGuard: lowConfirmationGuard)

        let result = try await engine.clean(
            items: [systemCacheItem(at: file)],
            dryRun: false,
            confirmedLargeDeletion: true
        )

        #expect(result.itemsProcessed == 1)
        let calls = await recorder.items(for: "system-cache")
        #expect(calls.count == 1)
    }

    @Test func dryRunOverThresholdNeverRequiresConfirmation() async throws {
        let recorder = CleanupRecorder()
        let engine = ScanEngine(modules: [
            TestModule(id: "system-cache", name: "System Cache", description: "System Cache", recorder: recorder),
        ])

        // A preview touches nothing, so it is never gated regardless of size.
        let result = try await engine.clean(
            items: [systemCacheItem(
                at: FileManager.default.temporaryDirectory.appendingPathComponent("large.cache"),
                storedSize: 2_000_000_000
            )],
            dryRun: true
        )
        #expect(result.itemsProcessed == 1)
    }

    @Test func cleanBlocksContentThatGrewAfterScanBeforeModuleDispatch() async throws {
        let temp = try TempTestDirectory(prefix: "ScanEngineGrowth")
        let file = temp.appendingPathComponent("growing.cache")
        try Data(repeating: 0x11, count: 262_144).write(to: file)
        let scannedItem = systemCacheItem(at: file, storedSize: 262_144)

        // Simulate content growth after scan metadata was captured.
        try Data(repeating: 0x22, count: 2_097_152).write(to: file)

        let recorder = CleanupRecorder()
        let engine = ScanEngine(modules: [
            TestModule(id: "system-cache", name: "System Cache", description: "System Cache", recorder: recorder),
        ], deletionGuard: DeletionGuard(
            maxTotalSize: 1_048_576,
            confirmationThreshold: 524_288,
            dryRunDefault: true
        ))

        do {
            _ = try await engine.clean(
                items: [scannedItem],
                dryRun: false,
                confirmedLargeDeletion: true
            )
            Issue.record("Expected live post-scan growth to block deletion")
        } catch let error as ScanEngineError {
            guard case .deletionBlocked(let reason) = error else {
                Issue.record("Expected .deletionBlocked, got \(error)")
                return
            }
            #expect(reason.contains("exceeds maximum"))
        }

        #expect(await recorder.items(for: "system-cache").isEmpty)
    }

    @Test func cleanRemeasuresLaterModuleAndCarriesForwardEarlierImpact() async throws {
        let temp = try TempTestDirectory(prefix: "ScanEngineSequentialGrowth")
        let cacheDirectory = temp.appendingPathComponent("Caches")
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: false
        )
        let first = cacheDirectory.appendingPathComponent("first.cache")
        let later = cacheDirectory.appendingPathComponent("later.cache")
        try Data(repeating: 0x11, count: 65_536).write(to: first)
        try Data(repeating: 0x22, count: 65_536).write(to: later)

        let recorder = CleanupRecorder()
        let engine = ScanEngine(modules: [
            GrowingTestModule(
                id: "alpha",
                name: "Alpha",
                description: "Alpha",
                recorder: recorder,
                targetToGrow: later
            ),
            TestModule(id: "beta", name: "Beta", description: "Beta", recorder: recorder),
        ], deletionGuard: DeletionGuard(
            maxTotalSize: 1_048_576,
            confirmationThreshold: 1_048_576,
            dryRunDefault: true
        ))

        let firstItem = CleanupItem(
            id: UUID(),
            path: first,
            size: 65_536,
            type: .file,
            module: "alpha",
            moduleName: "Alpha"
        )
        let laterItem = CleanupItem(
            id: UUID(),
            path: later,
            size: 65_536,
            type: .file,
            module: "beta",
            moduleName: "Beta"
        )

        do {
            _ = try await engine.clean(
                items: [firstItem, laterItem],
                dryRun: false,
                confirmedLargeDeletion: true
            )
            Issue.record("Expected later growth to exceed the cumulative hard cap")
        } catch let error as ScanEngineError {
            guard case .deletionBlocked(let reason) = error else {
                Issue.record("Expected .deletionBlocked, got \(error)")
                return
            }
            #expect(reason.contains("exceeds maximum"))
        }

        #expect(await recorder.items(for: "alpha") == [firstItem])
        #expect(await recorder.items(for: "beta").isEmpty)
    }

    // MARK: - Partial-scan diagnostics

    struct ScanFailure: Error {}

    actor ProgressRecorder {
        private var updates: [ScanProgressUpdate] = []

        func record(_ update: ScanProgressUpdate) {
            updates.append(update)
        }

        func allUpdates() -> [ScanProgressUpdate] {
            updates
        }
    }

    /// A module whose scan() either throws or returns a fixed set of items,
    /// for exercising partial-scan capture without touching the real filesystem.
    struct ScanOutcomeModule: ScanModule {
        let id: String
        let name: String
        let description: String
        let icon: String = "testtube.2"
        let shouldThrow: Bool
        let itemsToReturn: [CleanupItem]

        func scan() async throws -> [CleanupItem] {
            if shouldThrow { throw ScanFailure() }
            return itemsToReturn
        }

        func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
            CleanupResult(itemsProcessed: 0, bytesFreed: 0)
        }
    }

    struct CancelledScanModule: ScanModule {
        let id: String
        let name: String
        let description: String
        let icon: String = "testtube.2"

        func scan() async throws -> [CleanupItem] {
            throw CancellationError()
        }

        func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
            CleanupResult(itemsProcessed: 0, bytesFreed: 0)
        }
    }

    @Test func scanWithDiagnosticsCapturesModuleFailures() async {
        // A temp-dir path resolves under /var/folders (a safe cache root), so the
        // healthy module's item survives the scan-time safety filter.
        let tmp = FileManager.default.temporaryDirectory
        let healthyItem = CleanupItem(
            id: UUID(),
            path: tmp.appendingPathComponent("healthy.tmp"),
            size: 256,
            type: .file,
            module: "healthy",
            moduleName: "Healthy"
        )

        let engine = ScanEngine(modules: [
            ScanOutcomeModule(id: "healthy", name: "Healthy", description: "Healthy",
                              shouldThrow: false, itemsToReturn: [healthyItem]),
            ScanOutcomeModule(id: "broken", name: "Broken", description: "Broken",
                              shouldThrow: true, itemsToReturn: []),
        ])

        let result = await engine.scanWithDiagnostics()

        #expect(result.items == [healthyItem])
        #expect(result.isPartial)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.moduleID == "broken")
        #expect(result.failures.first?.moduleName == "Broken")
    }

    @Test func scanWithDiagnosticsReportsCompleteWhenNoFailures() async {
        let tmp = FileManager.default.temporaryDirectory
        let healthyItem = CleanupItem(
            id: UUID(),
            path: tmp.appendingPathComponent("healthy.tmp"),
            size: 256,
            type: .file,
            module: "healthy",
            moduleName: "Healthy"
        )

        let engine = ScanEngine(modules: [
            ScanOutcomeModule(id: "healthy", name: "Healthy", description: "Healthy",
                              shouldThrow: false, itemsToReturn: [healthyItem]),
        ])

        let result = await engine.scanWithDiagnostics()

        #expect(result.items == [healthyItem])
        #expect(!result.isPartial)
        #expect(result.failures.isEmpty)
    }

    @Test func scanWithDiagnosticsDoesNotSurfaceCancellationAsFailure() async {
        let tmp = FileManager.default.temporaryDirectory
        let healthyItem = CleanupItem(
            id: UUID(),
            path: tmp.appendingPathComponent("healthy.tmp"),
            size: 256,
            type: .file,
            module: "healthy",
            moduleName: "Healthy"
        )

        let engine = ScanEngine(modules: [
            ScanOutcomeModule(id: "healthy", name: "Healthy", description: "Healthy",
                              shouldThrow: false, itemsToReturn: [healthyItem]),
            CancelledScanModule(id: "cancelled", name: "Cancelled", description: "Cancelled"),
        ])

        let result = await engine.scanWithDiagnostics()

        #expect(result.items == [healthyItem])
        #expect(!result.isPartial)
        #expect(result.failures.isEmpty)
    }

    @Test func scanFailureClassifiesPermissionRecoveryAndProducesConciseReason() {
        let permissionFailure = ModuleScanFailure(
            moduleID: "mail-attachments",
            moduleName: "Mail Attachments",
            message: "Operation not permitted while reading Mail\nGrant access and retry."
        )
        let ordinaryFailure = ModuleScanFailure(
            moduleID: "docker",
            moduleName: "Docker",
            message: "Permission denied: " + String(repeating: "x", count: 200)
        )

        #expect(permissionFailure.requiresFullDiskAccess)
        #expect(
            permissionFailure.conciseMessage
                == "Operation not permitted while reading Mail Grant access and retry."
        )
        #expect(!ordinaryFailure.requiresFullDiskAccess)
        #expect(ordinaryFailure.conciseMessage.count == 158)
        #expect(ordinaryFailure.conciseMessage.hasSuffix("…"))
    }

    @Test func dockerActionsSurviveScanFilteringWithoutAllowingProtectedDockerPaths() async {
        let action = CleanupItem(
            id: UUID(),
            action: .docker(.pruneImages),
            size: 4096
        )
        let protectedPath = CleanupItem(
            id: UUID(),
            path: URL(fileURLWithPath: "/var/lib/docker/attacker-controlled"),
            size: 8192,
            type: .directory,
            module: "docker",
            moduleName: "Docker Images"
        )
        let engine = ScanEngine(modules: [
            ScanOutcomeModule(
                id: "docker",
                name: "Docker",
                description: "Docker",
                shouldThrow: false,
                itemsToReturn: [action, protectedPath]
            ),
        ])

        let result = await engine.scanWithDiagnostics()

        #expect(result.items == [action])
        #expect(result.items.first?.displayName == "All dangling Docker images")
        #expect(result.items.first?.size == 4096)
        #expect(result.items.first?.path.isFileURL == false)
    }

    @Test func scanShimDropsFailedModulesSilently() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let healthyItem = CleanupItem(
            id: UUID(),
            path: tmp.appendingPathComponent("healthy.tmp"),
            size: 256,
            type: .file,
            module: "healthy",
            moduleName: "Healthy"
        )

        let engine = ScanEngine(modules: [
            ScanOutcomeModule(id: "healthy", name: "Healthy", description: "Healthy",
                              shouldThrow: false, itemsToReturn: [healthyItem]),
            ScanOutcomeModule(id: "broken", name: "Broken", description: "Broken",
                              shouldThrow: true, itemsToReturn: []),
        ])

        // Back-compat shim returns only the items, swallowing the failure.
        let items = try await engine.scan()
        #expect(items == [healthyItem])
    }

    @Test func scanWithDiagnosticsReportsModuleProgress() async {
        let engine = ScanEngine(modules: [
            ScanOutcomeModule(id: "alpha", name: "Alpha", description: "Alpha",
                              shouldThrow: false, itemsToReturn: []),
            ScanOutcomeModule(id: "beta", name: "Beta", description: "Beta",
                              shouldThrow: true, itemsToReturn: []),
        ])
        let recorder = ProgressRecorder()

        _ = await engine.scanWithDiagnostics { update in
            await recorder.record(update)
        }

        let updates = await recorder.allUpdates()
        #expect(updates.first?.completedModules == 0)
        #expect(updates.first?.totalModules == 2)
        #expect(updates.last?.completedModules == 2)
        #expect(updates.last?.totalModules == 2)
        #expect(updates.last?.fractionCompleted == 1)
        #expect(Set(updates.compactMap(\.moduleID)) == ["alpha", "beta"])
    }

    @Test func cleanAllowsOversizedDryRunPreview() async throws {
        let recorder = CleanupRecorder()
        let engine = ScanEngine(modules: [
            TestModule(id: "system-cache", name: "System Cache", description: "System Cache", recorder: recorder),
        ])

        let tmp = FileManager.default.temporaryDirectory
        let hugeItem = CleanupItem(
            id: UUID(),
            path: tmp.appendingPathComponent("huge.cache"),
            size: 11_000_000_000,  // > 10GB hard limit, but dry-run previews are always allowed
            type: .file,
            module: "system-cache",
            moduleName: "System Cache"
        )

        let result = try await engine.clean(items: [hugeItem], dryRun: true)
        #expect(result.itemsProcessed == 1)
        let calls = await recorder.items(for: "system-cache")
        #expect(calls == [hugeItem])
    }
}

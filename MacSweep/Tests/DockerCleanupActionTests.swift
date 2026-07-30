import Foundation
import Testing
@testable import MacSweepCore

/// End-to-end contract tests for Docker findings as typed, non-filesystem
/// cleanup actions. The command recorder is the security boundary assertion:
/// item labels and filesystem paths must never become executable argv.
struct DockerCleanupActionTests {
    actor CommandRecorder {
        struct Invocation: Equatable {
            let executable: String
            let arguments: [String]
        }

        private var invocations: [Invocation] = []
        private var dockerDFOutputs: [String]
        private let failingDFCalls: Set<Int>
        private var dockerDFCallCount = 0

        private static let zeroUsage = [
            #"{"Reclaimable":"0B","Type":"Build Cache"}"#,
            #"{"Reclaimable":"0B","Type":"Images"}"#,
            #"{"Reclaimable":"0B","Type":"Containers"}"#,
            #"{"Reclaimable":"0B","Type":"Local Volumes"}"#,
        ].joined(separator: "\n")

        init() {
            dockerDFOutputs = [Self.zeroUsage]
            failingDFCalls = []
        }

        init(dockerDFOutput: String) {
            dockerDFOutputs = [dockerDFOutput]
            failingDFCalls = []
        }

        init(dockerDFOutputs: [String], failingDFCalls: Set<Int> = []) {
            self.dockerDFOutputs = dockerDFOutputs
            self.failingDFCalls = failingDFCalls
        }

        func run(executable: String, arguments: [String]) -> ProcessResult {
            invocations.append(Invocation(executable: executable, arguments: arguments))
            if arguments == ["system", "df", "--format", "{{json .}}"] {
                dockerDFCallCount += 1
                if failingDFCalls.contains(dockerDFCallCount) {
                    return ProcessResult(status: 1, output: "", error: "Docker daemon unavailable")
                }
                let output = dockerDFOutputs.isEmpty ? "" : dockerDFOutputs.removeFirst()
                return ProcessResult(status: 0, output: output, error: "")
            }
            // Enumerated clean path: list exited containers / dangling volumes.
            if arguments == ["container", "ls", "-aq", "-f", "status=exited"] {
                return ProcessResult(status: 0, output: "aabbccddeeff\n", error: "")
            }
            if arguments == ["volume", "ls", "-q", "-f", "dangling=true"] {
                return ProcessResult(status: 0, output: "orphan_volume\n", error: "")
            }
            return ProcessResult(
                status: 0,
                output: "Total reclaimed space: 64MB\n",
                error: ""
            )
        }

        func recordedInvocations() -> [Invocation] {
            invocations
        }
    }

    private func module(recorder: CommandRecorder) -> DockerModule {
        DockerModule(
            dockerPath: { "/test/bin/docker" },
            commandRunner: { executable, arguments in
                await recorder.run(executable: executable, arguments: arguments)
            }
        )
    }

    @Test func everyTypedActionDisclosesItsExactCommandAndImpact() {
        #expect(Dictionary(uniqueKeysWithValues: DockerCleanupAction.allCases.map {
            ($0, $0.commandPreview)
        }) == [
            .pruneBuildCache: "docker builder prune -f",
            .pruneImages: "docker image prune -f",
            .pruneContainers: "docker container ls -aq -f status=exited && docker container rm <ids>",
            .pruneVolumes: "docker volume ls -q -f dangling=true && docker volume rm <names>"
        ])
        #expect(DockerCleanupAction.pruneBuildCache.impactDescription.localizedCaseInsensitiveContains("ALL unused"))
        #expect(DockerCleanupAction.pruneImages.impactDescription.localizedCaseInsensitiveContains("dangling"))
        #expect(DockerCleanupAction.pruneContainers.impactDescription.localizedCaseInsensitiveContains("stopped"))
        #expect(DockerCleanupAction.pruneVolumes.impactDescription.localizedCaseInsensitiveContains("permanently"))
    }

    @Test func scanSurfacesTypedActionsWithCanonicalLabelsAndReclaimableBytes() async throws {
        let output = [
            #"{"Reclaimable":"256MB (100%)","Type":"Build Cache"}"#,
            #"{"Reclaimable":"1.5GB (75%)","Type":"Images"}"#,
            #"{"Reclaimable":"0B","Type":"Containers"}"#,
            #"{"Reclaimable":"32MB (100%)","Type":"Local Volumes"}"#,
        ].joined(separator: "\n")
        let recorder = CommandRecorder(dockerDFOutput: output)
        let engine = ScanEngine(modules: [module(recorder: recorder)])

        let items = try await engine.scan(modules: ["docker"])
        let actions = items.filter { $0.type == .action }

        #expect(actions.count == 3)
        #expect(actions.allSatisfy { !$0.path.isFileURL })
        #expect(actions.allSatisfy { $0.path.scheme == "macsweep-action" })
        #expect(actions.allSatisfy { $0.module == "docker" && $0.moduleName == $0.displayName })
        #expect(Dictionary(uniqueKeysWithValues: actions.map { ($0.displayName, $0.size) }) == [
            "All unused Docker build cache": 256_000_000,
            "All dangling Docker images": 1_500_000_000,
            "All unused Docker volumes": 32_000_000,
        ])

        let preview = try await engine.clean(items: actions, dryRun: true)
        #expect(preview.itemsProcessed == 3)
        #expect(preview.bytesFreed == 1_788_000_000)
        #expect(await recorder.recordedInvocations().map(\.arguments) == [
            ["system", "df", "--format", "{{json .}}"],
        ])
    }

    @Test func everyTypedActionMapsToOneFixedAllowlistedCommand() async throws {
        let recorder = CommandRecorder()
        let docker = module(recorder: recorder)
        let items = DockerCleanupAction.allCases.map {
            CleanupItem(id: UUID(), action: .docker($0), size: 1)
        }

        let result = try await docker.clean(items: items, dryRun: false)
        let invocations = await recorder.recordedInvocations()

        #expect(result.itemsProcessed == DockerCleanupAction.allCases.count)
        // Each action has size 1; prune output is clamped to that declaration,
        // and list-then-rm credits the same declaration on success.
        #expect(result.bytesFreed == Int64(DockerCleanupAction.allCases.count))
        #expect(invocations.map(\.arguments) == [
            ["system", "df", "--format", "{{json .}}"],
            ["builder", "prune", "-f"],
            ["image", "prune", "-f"],
            ["volume", "ls", "-q", "-f", "dangling=true"],
            ["volume", "rm", "orphan_volume"],
            ["container", "ls", "-aq", "-f", "status=exited"],
            ["container", "rm", "aabbccddeeff"],
        ])
    }

    @Test func filesystemItemCannotSpoofAnExecutableDockerAction() async throws {
        let recorder = CommandRecorder()
        let docker = module(recorder: recorder)
        let spoofed = CleanupItem(
            id: UUID(),
            path: URL(fileURLWithPath: "/var/lib/docker/$(touch-pwned)"),
            size: 1024,
            type: .directory,
            module: "docker",
            moduleName: "Docker Images"
        )
        let unverified = CleanupItem(
            id: UUID(),
            action: .docker(.pruneVolumes),
            size: 0
        )

        let result = try await docker.clean(items: [spoofed, unverified], dryRun: false)
        let invocations = await recorder.recordedInvocations()

        #expect(invocations.isEmpty)
        #expect(result.itemsProcessed == 0)
        #expect(result.errors.count == 2)
    }

    @Test func deletionGuardBlocksOversizedDockerActionBeforeExecution() async {
        let recorder = CommandRecorder()
        let engine = ScanEngine(modules: [module(recorder: recorder)])
        let oversized = CleanupItem(
            id: UUID(),
            action: .docker(.pruneBuildCache),
            size: 10_737_418_241
        )

        do {
            _ = try await engine.clean(items: [oversized], dryRun: false)
            Issue.record("Expected the Docker action to be blocked by DeletionGuard")
        } catch let error as ScanEngineError {
            guard case .deletionBlocked = error else {
                Issue.record("Expected .deletionBlocked, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected ScanEngineError, got \(error)")
        }

        let invocations = await recorder.recordedInvocations()
        #expect(invocations.isEmpty)
    }

    @Test func terabyteScanEstimateIsBlockedBeforeDockerPrune() async throws {
        let output = #"{"Reclaimable":"12TB (100%)","Type":"Images"}"#
        let recorder = CommandRecorder(dockerDFOutput: output)
        let engine = ScanEngine(modules: [module(recorder: recorder)])

        let items = try await engine.scan(modules: ["docker"])
        let actions = items.filter { $0.type == .action }
        #expect(actions.count == 1)
        #expect(actions.first?.size == 12_000_000_000_000)

        do {
            _ = try await engine.clean(items: actions, dryRun: false)
            Issue.record("Expected parsed 12TB Docker impact to exceed the 10GiB hard cap")
        } catch let error as ScanEngineError {
            guard case .deletionBlocked = error else {
                Issue.record("Expected .deletionBlocked, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected ScanEngineError, got \(error)")
        }

        #expect(await recorder.recordedInvocations().map(\.arguments) == [
            ["system", "df", "--format", "{{json .}}"],
        ])
    }

    @Test func unknownDockerSizeUnitProducesNoCleanupAction() async throws {
        let output = #"{"Reclaimable":"12XB (100%)","Type":"Images"}"#
        let recorder = CommandRecorder(dockerDFOutput: output)
        let engine = ScanEngine(modules: [module(recorder: recorder)])

        let items = try await engine.scan(modules: ["docker"])

        #expect(items.allSatisfy { $0.type != .action })
        #expect(await recorder.recordedInvocations().map(\.arguments) == [
            ["system", "df", "--format", "{{json .}}"],
        ])
    }

    @Test func cleanupRefusesImpactThatGrewAfterScanBeforePrune() async throws {
        let scanned = #"{"Reclaimable":"1GB (100%)","Type":"Images"}"#
        let grown = #"{"Reclaimable":"12TB (100%)","Type":"Images"}"#
        let recorder = CommandRecorder(dockerDFOutputs: [scanned, grown])
        let engine = ScanEngine(modules: [module(recorder: recorder)])

        let actions = try await engine.scan(modules: ["docker"])
        let result = try await engine.clean(items: actions, dryRun: false)

        #expect(result.itemsProcessed == 0)
        #expect(result.bytesFreed == 0)
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.message.localizedCaseInsensitiveContains("rescan") == true)
        #expect(await recorder.recordedInvocations().map(\.arguments) == [
            ["system", "df", "--format", "{{json .}}"],
            ["system", "df", "--format", "{{json .}}"],
        ])
    }

    @Test func cleanupRefusesUnverifiableFreshImpactBeforePrune() async throws {
        let scanned = #"{"Reclaimable":"1GB (100%)","Type":"Images"}"#
        let malformed = #"{"Reclaimable":"12XB (100%)","Type":"Images"}"#
        let recorder = CommandRecorder(dockerDFOutputs: [scanned, malformed])
        let engine = ScanEngine(modules: [module(recorder: recorder)])

        let actions = try await engine.scan(modules: ["docker"])
        let result = try await engine.clean(items: actions, dryRun: false)

        #expect(result.itemsProcessed == 0)
        #expect(result.bytesFreed == 0)
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.message.localizedCaseInsensitiveContains("verify") == true)
        #expect(await recorder.recordedInvocations().map(\.arguments) == [
            ["system", "df", "--format", "{{json .}}"],
            ["system", "df", "--format", "{{json .}}"],
        ])
    }

    @Test func staleImpactInOneActionBlocksEntireDockerBatchBeforePrune() async throws {
        let fresh = [
            #"{"Reclaimable":"1B","Type":"Containers"}"#,
            #"{"Reclaimable":"12TB","Type":"Local Volumes"}"#,
        ].joined(separator: "\n")
        let recorder = CommandRecorder(dockerDFOutput: fresh)
        let docker = module(recorder: recorder)
        let items = [
            CleanupItem(id: UUID(), action: .docker(.pruneContainers), size: 1),
            CleanupItem(id: UUID(), action: .docker(.pruneVolumes), size: 1),
        ]

        let result = try await docker.clean(items: items, dryRun: false)

        #expect(result.itemsProcessed == 0)
        #expect(result.bytesFreed == 0)
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.message.localizedCaseInsensitiveContains("rescan") == true)
        #expect(await recorder.recordedInvocations().map(\.arguments) == [
            ["system", "df", "--format", "{{json .}}"],
        ])
    }

    @Test func failedBatchVerificationBlocksEveryDockerPrune() async throws {
        let fresh = [
            #"{"Reclaimable":"1B","Type":"Build Cache"}"#,
            #"{"Reclaimable":"1B","Type":"Images"}"#,
        ].joined(separator: "\n")
        let recorder = CommandRecorder(
            dockerDFOutputs: [fresh],
            failingDFCalls: [1]
        )
        let docker = module(recorder: recorder)
        let items = [
            CleanupItem(id: UUID(), action: .docker(.pruneBuildCache), size: 1),
            CleanupItem(id: UUID(), action: .docker(.pruneImages), size: 1),
        ]

        let result = try await docker.clean(items: items, dryRun: false)

        #expect(result.itemsProcessed == 0)
        #expect(result.bytesFreed == 0)
        #expect(result.errors.count == 2)
        #expect(result.errors.allSatisfy { $0.message.localizedCaseInsensitiveContains("rescan") })
        #expect(await recorder.recordedInvocations().map(\.arguments) == [
            ["system", "df", "--format", "{{json .}}"],
        ])
    }

    @Test func unknownFreshDockerCategoryBlocksPrune() async throws {
        let fresh = [
            #"{"Reclaimable":"1B","Type":"Images"}"#,
            #"{"Reclaimable":"1B","Type":"Unknown"}"#,
        ].joined(separator: "\n")
        let recorder = CommandRecorder(dockerDFOutput: fresh)
        let docker = module(recorder: recorder)
        let item = CleanupItem(id: UUID(), action: .docker(.pruneImages), size: 1)

        let result = try await docker.clean(items: [item], dryRun: false)

        #expect(result.itemsProcessed == 0)
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.message.localizedCaseInsensitiveContains("rescan") == true)
        #expect(await recorder.recordedInvocations().map(\.arguments) == [
            ["system", "df", "--format", "{{json .}}"],
        ])
    }
}

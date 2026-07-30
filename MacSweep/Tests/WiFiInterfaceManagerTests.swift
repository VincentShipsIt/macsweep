import Foundation
import Testing
@testable import MacSweepCore

struct WiFiInterfaceManagerTests {
    @Test func parseWiFiInterfacesExtractsDeviceNames() {
        let output = """
        Hardware Port: Ethernet
        Device: en0
        Ethernet Address: aa:bb:cc:dd:ee:ff

        Hardware Port: Wi-Fi
        Device: en1
        Ethernet Address: 11:22:33:44:55:66

        Hardware Port: Thunderbolt Bridge
        Device: bridge0
        """
        #expect(WiFiInterfaceManager.parseWiFiInterfaces(from: output) == ["en1"])
    }

    @Test func availableInterfacesUsesProcessRunnerAndTimeout() async {
        let recorder = WiFiCommandRecorder(outcome: .result(ProcessResult(
            status: 0,
            output: """
            Hardware Port: Wi-Fi
            Device: en7
            """,
            error: ""
        )))

        let interfaces = await WiFiInterfaceManager.availableInterfaces { executable, arguments, timeout in
            try await recorder.run(executable: executable, arguments: arguments, timeout: timeout)
        }

        #expect(interfaces == ["en7"])
        #expect(await recorder.recordedInvocations() == [
            WiFiCommandRecorder.Invocation(
                executable: "/usr/sbin/networksetup",
                arguments: ["-listallhardwareports"],
                timeout: WiFiInterfaceManager.listingTimeout
            )
        ])
        #expect(WiFiInterfaceManager.listingTimeout == 10)
    }

    @Test func availableInterfacesFallsBackToEn0OnFailure() async {
        let interfaces = await WiFiInterfaceManager.availableInterfaces { _, _, _ in
            throw ProcessRunnerError.timedOut(
                after: WiFiInterfaceManager.listingTimeout,
                partialResult: ProcessResult(status: -1, output: "", error: "timeout")
            )
        }
        #expect(interfaces == ["en0"])
    }
}

/// Local recorder (mirrors WiFiNetworkManager tests without coupling suites).
private actor WiFiCommandRecorder {
    struct Invocation: Equatable, Sendable {
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval
    }

    enum Outcome: Sendable {
        case result(ProcessResult)
        case failure(Error)
    }

    private let outcome: Outcome
    private var invocations: [Invocation] = []

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        invocations.append(Invocation(
            executable: executable,
            arguments: arguments,
            timeout: timeout
        ))
        switch outcome {
        case .result(let result):
            return result
        case .failure(let error):
            throw error
        }
    }

    func recordedInvocations() -> [Invocation] {
        invocations
    }
}

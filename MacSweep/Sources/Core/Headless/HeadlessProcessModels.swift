import Foundation

// MARK: - Processes

public struct HeadlessProcess: Codable, Sendable {
    public let pid: Int32
    public let name: String
    public let bundleID: String?
    public let memoryMB: Double
    public let cpuPercent: Double
    public let isActive: Bool

    public init(
        pid: Int32,
        name: String,
        bundleID: String?,
        memoryMB: Double,
        cpuPercent: Double,
        isActive: Bool
    ) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.memoryMB = memoryMB
        self.cpuPercent = cpuPercent
        self.isActive = isActive
    }
}

public struct HeadlessProcessReport: Codable, Sendable {
    public let sortOrder: String   // "memory" | "cpu" | "name"
    public let totalProcesses: Int
    public let processes: [HeadlessProcess]

    public init(sortOrder: String, totalProcesses: Int, processes: [HeadlessProcess]) {
        self.sortOrder = sortOrder
        self.totalProcesses = totalProcesses
        self.processes = processes
    }
}

public struct HeadlessProcessQuitResult: Codable, Sendable {
    public let pid: Int32
    public let name: String
    public let forced: Bool
    public let terminated: Bool

    public init(pid: Int32, name: String, forced: Bool, terminated: Bool) {
        self.pid = pid
        self.name = name
        self.forced = forced
        self.terminated = terminated
    }
}


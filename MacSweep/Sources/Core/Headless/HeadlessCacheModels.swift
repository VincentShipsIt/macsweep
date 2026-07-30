import Foundation

// MARK: - Cache Analysis

public struct HeadlessCacheFinding: Codable, Sendable {
    public let path: String
    /// Exact on-disk size for deterministic fast-scan findings; `nil` for AI
    /// findings, whose sizes are free-text estimates (see `sizeText`).
    public let sizeBytes: Int64?
    public let sizeText: String
    public let category: String
    public let regeneratesAutomatically: Bool
    public let source: String
    public let reason: String?

    public init(
        path: String,
        sizeBytes: Int64?,
        sizeText: String,
        category: String,
        regeneratesAutomatically: Bool,
        source: String,
        reason: String?
    ) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.sizeText = sizeText
        self.category = category
        self.regeneratesAutomatically = regeneratesAutomatically
        self.source = source
        self.reason = reason
    }
}

public struct HeadlessCacheReport: Codable, Sendable {
    public let fastScanCount: Int
    public let aiScanRequested: Bool
    public let aiScanRan: Bool
    public let totalFindings: Int
    public let findings: [HeadlessCacheFinding]
    public let errors: [String]

    public init(
        fastScanCount: Int,
        aiScanRequested: Bool,
        aiScanRan: Bool,
        totalFindings: Int,
        findings: [HeadlessCacheFinding],
        errors: [String]
    ) {
        self.fastScanCount = fastScanCount
        self.aiScanRequested = aiScanRequested
        self.aiScanRan = aiScanRan
        self.totalFindings = totalFindings
        self.findings = findings
        self.errors = errors
    }
}


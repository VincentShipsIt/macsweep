import Foundation

// MARK: - Shred

public struct HeadlessShredResult: Codable, Sendable {
    public let path: String
    public let level: String
    public let isDirectory: Bool
    public let filesShredded: Int
    public let bytesShredded: Int64
    public let success: Bool
    public let errors: [String]

    public init(
        path: String,
        level: String,
        isDirectory: Bool,
        filesShredded: Int,
        bytesShredded: Int64,
        success: Bool,
        errors: [String]
    ) {
        self.path = path
        self.level = level
        self.isDirectory = isDirectory
        self.filesShredded = filesShredded
        self.bytesShredded = bytesShredded
        self.success = success
        self.errors = errors
    }
}


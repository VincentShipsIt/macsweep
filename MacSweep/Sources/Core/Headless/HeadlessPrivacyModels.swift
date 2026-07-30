import Foundation

// MARK: - Privacy Actions

public struct HeadlessPrivacyActionResult: Codable, Sendable {
    public let action: String   // "clear-clipboard" | "clear-terminal-history" | "clear-recent-docs"
    public let success: Bool
    public let message: String

    public init(action: String, success: Bool, message: String) {
        self.action = action
        self.success = success
        self.message = message
    }
}


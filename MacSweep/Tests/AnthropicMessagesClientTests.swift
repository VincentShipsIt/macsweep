import Foundation
import Testing
@testable import MacSweepCore

struct AnthropicMessagesClientTests {
    @Test func extractJSONArrayPrefersBracketSlice() {
        let prose = """
        Here you go:
        [{"a":1},{"b":2}]
        thanks
        """
        #expect(AnthropicMessagesClient.extractJSONArray(from: prose) == "[{\"a\":1},{\"b\":2}]")
    }

    @Test func extractJSONArrayStripsMarkdownFence() {
        let fenced = """
        ```json
        [{"summary":"ok"}]
        ```
        """
        #expect(AnthropicMessagesClient.extractJSONArray(from: fenced) == "[{\"summary\":\"ok\"}]")
    }

    @Test func stripMarkdownFenceLeavesPlainText() {
        #expect(AnthropicMessagesClient.stripMarkdownFence("  plain  ") == "plain")
    }

    @Test func modelRawValuesMatchPriorCallSites() {
        #expect(AnthropicMessagesClient.Model.haiku.rawValue == "claude-haiku-4-5")
        #expect(AnthropicMessagesClient.Model.sonnet.rawValue == "claude-sonnet-4-5")
        #expect(AnthropicMessagesClient.Model.opus.rawValue == "claude-opus-4-5")
    }
}

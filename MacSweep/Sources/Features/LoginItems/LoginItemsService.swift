import Foundation

/// GUI-facing login-items facade. Enumeration and mutation live in Core
/// (`LoginItemEnumerator` / `LoginItemController`); this type only owns
/// `@Published` UI state and the optional AI analysis pass.
@MainActor
final class LoginItemsService: ObservableObject {
    static let shared = LoginItemsService()

    @Published var items: [LoginItem] = []
    @Published var isLoading = false
    @Published var isAnalyzing = false
    @Published var errorMessage: String?

    private let enumerator = LoginItemEnumerator()
    private let controller = LoginItemController()

    private init() {}

    // MARK: - Scan

    func scan() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let headless = await enumerator.enumerate()
        items = headless.map(Self.makeLoginItem(from:))
    }

    // MARK: - Enable / Disable

    @discardableResult
    func setEnabled(_ enabled: Bool, for item: LoginItem) async -> Bool {
        guard item.type != .appService else { return false }

        do {
            _ = try await controller.setEnabled(enabled, label: item.name)
        } catch LoginItemController.MutationError.notFound {
            errorMessage = "Couldn't locate \(item.name)'s plist. Rescan login items and try again."
            return false
        } catch LoginItemController.MutationError.ambiguous {
            errorMessage = "Multiple plists match \(item.name). Resolve the conflict manually."
            return false
        } catch {
            errorMessage = "Couldn't update \(item.name): \(error.localizedDescription)"
            return false
        }

        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].isEnabled = enabled
        }
        return true
    }

    // MARK: - Delete

    func delete(_ item: LoginItem) async {
        guard item.type != .appService else { return }

        do {
            _ = try await controller.remove(label: item.name)
        } catch LoginItemController.MutationError.notFound {
            errorMessage = "Couldn't locate \(item.name)'s plist. Rescan login items and try again."
            return
        } catch {
            errorMessage = "Couldn't remove \(item.name): \(error.localizedDescription)"
            return
        }
        items.removeAll { $0.id == item.id }
    }

    // MARK: - AI Analysis

    func analyzeWithAI() async {
        guard !items.isEmpty else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }

        guard let apiKey = loadAPIKey() else {
            errorMessage = "No API key found. Add your Anthropic key in Settings."
            return
        }

        let itemsPayload = items.map { item in
            ["name": item.name, "path": item.path, "bundleId": item.bundleIdentifier ?? ""]
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: itemsPayload),
              let jsonString = String(data: jsonData, encoding: .utf8)
        else { return }

        let prompt = """
        Analyze these login items and launch agents. For each, provide: a plain English explanation of what it does, risk level (safe/suspicious/unknown), and recommendation.
        Items: \(jsonString)
        Return a JSON array matching input order (same count): [{"summary":"...","riskLevel":"safe|suspicious|unknown","recommendation":"..."}]
        Return ONLY the JSON array, no other text.
        """

        do {
            let text = try await AnthropicMessagesClient.complete(
                prompt: prompt,
                apiKey: apiKey,
                model: .opus,
                maxTokens: 4096,
                system: "You are a macOS security expert analyzing startup items. Be concise and accurate."
            )
            let cleaned = AnthropicMessagesClient.extractJSONArray(from: text)
            guard let analysisData = cleaned.data(using: .utf8),
                  let analyses = try? JSONDecoder().decode([AIItemAnalysisResponse].self, from: analysisData)
            else {
                errorMessage = "AI analysis returned an unparseable response."
                return
            }

            for (idx, analysis) in analyses.enumerated() where idx < items.count {
                items[idx].aiAnalysis = AIItemAnalysis(
                    summary: analysis.summary,
                    riskLevel: RiskLevel(rawValue: analysis.riskLevel) ?? .unknown,
                    recommendation: analysis.recommendation,
                    lastSeenDaysAgo: nil
                )
            }
        } catch {
            errorMessage = "AI analysis failed: \(error.localizedDescription)"
        }
    }

    private func loadAPIKey() -> String? {
        if let key = AIKeychainService.shared.loadKey() {
            return key
        }
        return ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
    }

    private static func makeLoginItem(from headless: HeadlessLoginItem) -> LoginItem {
        LoginItem(
            id: UUID(),
            name: headless.name,
            path: headless.path,
            type: loginItemType(for: headless.kind),
            bundleIdentifier: headless.bundleIdentifier,
            isEnabled: headless.enabled,
            aiAnalysis: nil,
            plistPath: headless.plistPath
        )
    }

    private static func loginItemType(for kind: HeadlessLoginItemKind) -> LoginItemType {
        switch kind {
        case .appService: return .appService
        case .launchAgent: return .launchAgent
        case .launchDaemon: return .launchDaemon
        }
    }
}

// MARK: - Decoding helper

private struct AIItemAnalysisResponse: Decodable {
    let summary: String
    let riskLevel: String
    let recommendation: String
}

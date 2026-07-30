import Foundation

@MainActor
class AIAnalysisService: ObservableObject {
    static let shared = AIAnalysisService()

    @Published var findings: [CacheFinding] = []
    @Published var isScanning = false
    @Published var phase = ""
    @Published var error: String?

    func scan() async {
        isScanning = true
        findings = []
        error = nil

        phase = "Scanning caches..."
        let result = await CacheAnalyzer().analyze(deep: true)
        findings = result.findings.map { finding in
            CacheFinding(
                path: finding.path,
                size: finding.sizeText,
                category: CacheCategory(rawValue: finding.category.rawValue) ?? .other,
                regeneratesAutomatically: finding.regeneratesAutomatically,
                source: finding.source == "Fast Scan" ? .deterministic : .ai,
                reason: finding.reason
            )
        }
        error = result.errors.isEmpty ? nil : result.errors.joined(separator: "; ")
        phase = result.aiRan ? "Done" : "Fast scan results only"
        isScanning = false
    }
}

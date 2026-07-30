import Foundation

/// Module for cleaning up developer tool artifacts
struct DevToolsModule: ScanModule {
    static let defaultMaxDepth = 6

    let id = "dev-tools"
    let name = "Developer Tools"
    let description = "Clean node_modules, DerivedData, build artifacts"
    let icon = "wrench.and.screwdriver"

    /// Search paths for dev artifacts
    var searchPaths: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser
    ]

    /// Maximum depth to search for projects
    var maxDepth: Int = Self.defaultMaxDepth

    func scan() async throws -> [CleanupItem] {
        var items: [CleanupItem] = []

        let patterns = DevArtifactPattern.allPatterns

        for searchPath in searchPaths {
            let found = await scanForPatterns(patterns, in: searchPath)
            items.append(contentsOf: found)
        }

        // Fixed Xcode / tooling cache locations under ~/Library, gated by the
        // shared exists+size helper.
        //
        // npm / pnpm / Bun / pip / cargo / Homebrew caches are intentionally NOT
        // scanned here. PackageManagerModule already covers them with correctly
        // SCOPED paths (~/.npm/_cacache, ~/.cargo/registry/cache, …). DevTools
        // previously registered the broad parents (whole ~/.npm, all of
        // ~/.cargo/registry — which also holds the `src/` tarballs cargo needs),
        // double-counting the same bytes and risking over-deletion.
        let library = URL.libraryDirectory
        let fixedTargets: [(path: String, name: String)] = [
            ("Developer/Xcode/DerivedData", "Xcode DerivedData"),
            ("Developer/Xcode/Archives", "Xcode Archives"),
            ("Developer/Xcode/iOS DeviceSupport", "iOS Device Support"),
            ("Caches/ms-playwright", "Playwright Browsers"),
            ("Developer/CoreSimulator/Devices", "iOS Simulators"),
        ]
        for target in fixedTargets {
            if let item = await scanCacheDirectory(at: library.appending(path: target.path), moduleName: target.name) {
                items.append(item)
            }
        }

        return items.sorted { $0.size > $1.size }
    }

    private func scanForPatterns(_ patterns: [DevArtifactPattern], in baseURL: URL) async -> [CleanupItem] {
        var items: [CleanupItem] = []

        guard let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        while let url = enumerator.nextObject() as? URL {
            // Depth is derived inline from path components on each visit.
            let pathComponents = url.pathComponents.count - baseURL.pathComponents.count
            if pathComponents > maxDepth {
                enumerator.skipDescendants()
                continue
            }

            // Skip certain directories to speed up scanning
            let name = url.lastPathComponent
            if name == ".git" || name == ".svn" || name == "Library" {
                enumerator.skipDescendants()
                continue
            }

            // Check against patterns
            for pattern in patterns {
                if pattern.matches(url) {
                    // Safety check
                    let checker = SafetyChecker()
                    guard checker.validateForScan(url, moduleID: id).isSafe else { continue }

                    let size = (try? await DiskAnalyzer.directorySize(at: url)) ?? 0
                    guard size > 1_048_576 else { continue }  // Skip if < 1MB

                    // Skip artifacts whose project shows recent activity: a build
                    // may be in progress, and removing artifacts mid-build can
                    // corrupt it. Regenerable and removed to Trash, so this is
                    // best-effort hardening, not a data-loss stop.
                    if Self.projectHasRecentActivity(forArtifactAt: url) {
                        enumerator.skipDescendants()
                        break
                    }

                    items.append(CleanupItem(
                        id: UUID(),
                        path: url,
                        size: size,
                        type: .directory,
                        module: id,
                        moduleName: pattern.name,
                        lastModified: try? url.resourceValues(
                            forKeys: [.contentModificationDateKey]
                        ).contentModificationDate
                    ))

                    // Don't descend into matched directories
                    enumerator.skipDescendants()
                    break
                }
            }
        }

        return items
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        await cleanItems(items, dryRun: dryRun) { item, _ in
            try CleanupFileRemover.recoverable(item.path, module: item.module)
        }
    }

    /// A project is "active" if a source/config file was modified within this
    /// window. 3 days spans a normal work break (e.g. a weekend).
    static let activeProjectWindow: TimeInterval = 3 * 24 * 60 * 60

    /// Directory names that are themselves regenerable build artifacts — their
    /// mtime bumps on every build, so they're excluded from the activity signal.
    private static let artifactDirectoryNames: Set<String> =
        Set(DevArtifactPattern.allPatterns.map(\.directoryName))

    /// True if the artifact's project root shows recent activity.
    ///
    /// Cheap shallow heuristic: the newest content-modification date among the
    /// parent directory's direct children, skipping regenerable artifact
    /// directories and VCS metadata (both churn independently of real work). A
    /// recently touched `package.json`, lockfile, or top-level source file trips
    /// it. Deep edits that touch no root-level file are not detected — acceptable
    /// for a best-effort, Trash-recoverable gate that avoids walking whole trees
    /// mid-scan.
    static func projectHasRecentActivity(forArtifactAt artifactURL: URL) -> Bool {
        let parent = artifactURL.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else { return false }

        let skip = artifactDirectoryNames.union([".git", ".svn", ".hg", ".DS_Store"])
        let cutoff = Date().addingTimeInterval(-activeProjectWindow)

        for entry in entries {
            if skip.contains(entry.lastPathComponent) { continue }
            if let modified = try? entry.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate, modified > cutoff {
                return true
            }
        }
        return false
    }
}

// MARK: - Dev Artifact Patterns

struct DevArtifactPattern {
    let name: String
    let directoryName: String
    let siblingIndicators: [String]  // Files that indicate this is a project root
    /// Which per-project browser bucket (ProjectScanner.discoverProjects) this
    /// artifact belongs to. `nil` marks machine-global caches (ms-playwright,
    /// .pnpm-store) that aren't tied to a single project root and so never appear
    /// in the per-project breakdown.
    let projectType: ProjectType?

    func matches(_ url: URL) -> Bool {
        guard url.lastPathComponent == directoryName else { return false }

        // Check for sibling files that indicate a project root
        let parent = url.deletingLastPathComponent()

        for indicator in siblingIndicators {
            if Self.parentContainsFile(matching: indicator, in: parent) {
                return true
            }
        }

        // If no indicators specified, just match the directory name
        return siblingIndicators.isEmpty
    }

    /// Sibling-indicator match. `fileExists` does NOT interpret shell globs, so a
    /// `"*.csproj"` indicator (used by the .NET/Xcode patterns) would look for a
    /// file literally named `*.csproj` and never match. For a `*.ext` glob we
    /// enumerate the directory and match by suffix; everything else keeps the fast
    /// exact-name `fileExists` path.
    private static func parentContainsFile(matching glob: String, in parent: URL) -> Bool {
        guard glob.hasPrefix("*.") else {
            return FileManager.default.fileExists(atPath: parent.appending(path: glob).path)
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        return entries.contains { indicator(glob, matchesFilename: $0) }
    }

    /// Whether `filename` satisfies an indicator entry: exact name, or suffix
    /// match for the "*.ext" glob form the .NET/Xcode indicators use.
    static func indicator(_ indicator: String, matchesFilename filename: String) -> Bool {
        guard indicator.hasPrefix("*.") else { return filename == indicator }
        return filename.hasSuffix(String(indicator.dropFirst(1)))   // "*.csproj" -> ".csproj"
    }

    /// Project type for a file that marks a project root, derived from
    /// `allPatterns` so the per-project browser (ProjectScanner.discoverProjects)
    /// can never drift from the cleanup scan's table again. Returns nil for
    /// filenames that are no pattern's sibling indicator.
    static func projectType(forRootIndicator filename: String) -> ProjectType? {
        for pattern in allPatterns {
            guard let type = pattern.projectType else { continue }
            if pattern.siblingIndicators.contains(where: { indicator($0, matchesFilename: filename) }) {
                return type
            }
        }
        return nil
    }

    /// Every artifact directory to check inside a project root of the given type,
    /// derived from `allPatterns` (order-preserving, deduplicated). Includes
    /// empty-indicator patterns like `__pycache__` — they can't act as root
    /// indicators but still belong to their ecosystem's artifact list — plus the
    /// path-shaped extras `matches(_:)`'s lastPathComponent comparison can't
    /// express (Ruby's vendor/bundle).
    static func artifactDirectories(for type: ProjectType) -> [String] {
        var seen = Set<String>()
        var directories: [String] = []
        for pattern in allPatterns where pattern.projectType == type {
            if seen.insert(pattern.directoryName).inserted {
                directories.append(pattern.directoryName)
            }
        }
        for extra in extraArtifactDirectories[type] ?? [] where seen.insert(extra).inserted {
            directories.append(extra)
        }
        return directories
    }

    /// Artifact locations that are relative paths rather than directory names, so
    /// they can't live in `allPatterns` (whose `matches(_:)` compares a single
    /// path component).
    private static let extraArtifactDirectories: [ProjectType: [String]] = [
        .ruby: ["vendor/bundle"]
    ]

    static let allPatterns: [DevArtifactPattern] = [
        // JavaScript/TypeScript
        DevArtifactPattern(
            name: "node_modules",
            directoryName: "node_modules",
            siblingIndicators: ["package.json"],
            projectType: .nodejs
        ),

        // Swift Package Manager
        DevArtifactPattern(
            name: "Swift .build",
            directoryName: ".build",
            siblingIndicators: ["Package.swift"],
            projectType: .swift
        ),

        // CocoaPods
        DevArtifactPattern(
            name: "CocoaPods",
            directoryName: "Pods",
            siblingIndicators: ["Podfile"],
            projectType: .xcode
        ),

        // Rust
        DevArtifactPattern(
            name: "Rust target",
            directoryName: "target",
            siblingIndicators: ["Cargo.toml"],
            projectType: .rust
        ),

        // Python
        DevArtifactPattern(
            name: "Python __pycache__",
            directoryName: "__pycache__",
            siblingIndicators: [],  // Can appear anywhere
            projectType: .python
        ),
        DevArtifactPattern(
            name: "Python .venv",
            directoryName: ".venv",
            siblingIndicators: ["requirements.txt", "pyproject.toml", "setup.py"],
            projectType: .python
        ),
        DevArtifactPattern(
            name: "Python venv",
            directoryName: "venv",
            siblingIndicators: ["requirements.txt", "pyproject.toml", "setup.py"],
            projectType: .python
        ),
        DevArtifactPattern(
            name: "pytest cache",
            directoryName: ".pytest_cache",
            siblingIndicators: ["pytest.ini", "pyproject.toml", "setup.py"],
            projectType: .python
        ),
        DevArtifactPattern(
            name: "mypy cache",
            directoryName: ".mypy_cache",
            siblingIndicators: ["pyproject.toml", "setup.py", "mypy.ini", ".mypy.ini"],
            projectType: .python
        ),

        // Gradle (Android/Java)
        DevArtifactPattern(
            name: "Gradle .gradle",
            directoryName: ".gradle",
            siblingIndicators: ["build.gradle", "build.gradle.kts", "settings.gradle"],
            projectType: .java
        ),
        DevArtifactPattern(
            name: "Gradle build",
            directoryName: "build",
            siblingIndicators: ["build.gradle", "build.gradle.kts"],
            projectType: .java
        ),

        // Go
        DevArtifactPattern(
            name: "Go vendor",
            directoryName: "vendor",
            siblingIndicators: ["go.mod"],
            projectType: .go
        ),

        // PHP
        DevArtifactPattern(
            name: "PHP vendor",
            directoryName: "vendor",
            siblingIndicators: ["composer.json"],
            projectType: .php
        ),

        // Ruby
        DevArtifactPattern(
            name: "Ruby .bundle",
            directoryName: ".bundle",
            siblingIndicators: ["Gemfile"],
            projectType: .ruby
        ),

        // .NET
        DevArtifactPattern(
            name: ".NET bin",
            directoryName: "bin",
            siblingIndicators: ["*.csproj", "*.fsproj"],
            projectType: .dotnet
        ),
        DevArtifactPattern(
            name: ".NET obj",
            directoryName: "obj",
            siblingIndicators: ["*.csproj", "*.fsproj"],
            projectType: .dotnet
        ),

        // Xcode (project-specific)
        DevArtifactPattern(
            name: "Xcode build",
            directoryName: "build",
            siblingIndicators: ["*.xcodeproj", "*.xcworkspace"],
            projectType: .xcode
        ),

        // CMake
        DevArtifactPattern(
            name: "CMake build",
            directoryName: "build",
            siblingIndicators: ["CMakeLists.txt"],
            projectType: .cmake
        ),

        // Bun
        DevArtifactPattern(
            name: "Bun lockfile",
            directoryName: "node_modules",
            siblingIndicators: ["bun.lockb"],
            projectType: .nodejs
        ),

        // Next.js
        DevArtifactPattern(
            name: "Next.js build",
            directoryName: ".next",
            siblingIndicators: ["next.config.js", "next.config.mjs", "next.config.ts"],
            projectType: .nodejs
        ),

        // Nuxt.js
        DevArtifactPattern(
            name: "Nuxt.js build",
            directoryName: ".nuxt",
            siblingIndicators: ["nuxt.config.js", "nuxt.config.ts"],
            projectType: .nodejs
        ),

        // Turborepo
        DevArtifactPattern(
            name: "Turbo cache",
            directoryName: ".turbo",
            siblingIndicators: ["turbo.json"],
            projectType: .nodejs
        ),

        // General dist/build output
        DevArtifactPattern(
            name: "dist folder",
            directoryName: "dist",
            siblingIndicators: ["package.json", "tsconfig.json"],
            projectType: .nodejs
        ),

        // Parcel
        DevArtifactPattern(
            name: "Parcel cache",
            directoryName: ".parcel-cache",
            siblingIndicators: ["package.json"],
            projectType: .nodejs
        ),

        // Vite
        DevArtifactPattern(
            name: "Vite cache",
            directoryName: ".vite",
            siblingIndicators: ["vite.config.js", "vite.config.ts"],
            projectType: .nodejs
        ),

        // ESLint
        DevArtifactPattern(
            name: "ESLint cache",
            directoryName: ".eslintcache",
            siblingIndicators: [".eslintrc.js", ".eslintrc.json", "eslint.config.js"],
            projectType: .nodejs
        ),

        // General cache directories
        DevArtifactPattern(
            name: "Cache folder",
            directoryName: ".cache",
            siblingIndicators: ["package.json"],
            projectType: .nodejs
        ),

        // Bun
        DevArtifactPattern(
            name: "Bun cache",
            directoryName: ".bun",
            siblingIndicators: ["bun.lockb", "bun.lock"],
            projectType: .nodejs
        ),

        // pnpm
        DevArtifactPattern(
            name: "pnpm store",
            directoryName: ".pnpm-store",
            siblingIndicators: [],
            projectType: nil  // machine-global store, not a per-project artifact
        ),
        DevArtifactPattern(
            name: "pnpm virtual store",
            directoryName: ".pnpm",
            siblingIndicators: ["pnpm-lock.yaml"],
            projectType: .nodejs
        ),

        // Playwright browsers
        DevArtifactPattern(
            name: "Playwright browsers",
            directoryName: "ms-playwright",
            siblingIndicators: [],
            projectType: nil  // machine-global cache, not a per-project artifact
        ),

        // Cypress
        DevArtifactPattern(
            name: "Cypress cache",
            directoryName: ".cypress",
            siblingIndicators: ["cypress.config.js", "cypress.config.ts"],
            projectType: .nodejs
        ),

        // Biome
        DevArtifactPattern(
            name: "Biome cache",
            directoryName: ".biome",
            siblingIndicators: ["biome.json", "biome.jsonc"],
            projectType: .nodejs
        ),

        // Webpack
        DevArtifactPattern(
            name: "Webpack cache",
            directoryName: ".webpack",
            siblingIndicators: ["webpack.config.js", "webpack.config.ts"],
            projectType: .nodejs
        ),

        // Storybook
        DevArtifactPattern(
            name: "Storybook cache",
            directoryName: ".storybook-cache",
            siblingIndicators: [".storybook"],
            projectType: .nodejs
        ),

        // Angular
        DevArtifactPattern(
            name: "Angular cache",
            directoryName: ".angular",
            siblingIndicators: ["angular.json"],
            projectType: .nodejs
        ),

        // Nx
        DevArtifactPattern(
            name: "Nx cache",
            directoryName: ".nx",
            siblingIndicators: ["nx.json"],
            projectType: .nodejs
        ),

        // Yarn
        DevArtifactPattern(
            name: "Yarn cache",
            directoryName: ".yarn",
            siblingIndicators: [".yarnrc.yml"],
            projectType: .nodejs
        ),

        // Coverage reports
        DevArtifactPattern(
            name: "Coverage reports",
            directoryName: "coverage",
            siblingIndicators: ["package.json", "vitest.config.ts", "jest.config.js"],
            projectType: .nodejs
        ),
    ]
}

// MARK: - Project Discovery

struct ProjectInfo: Identifiable {
    let id = UUID()
    let path: URL
    let type: ProjectType
    let artifactPaths: [URL]
    var artifactSize: Int64 = 0
    var lastModified: Date?

    var name: String {
        path.lastPathComponent
    }

    var formattedSize: String {
        artifactSize.formattedFileSize
    }

    /// Whether the project was modified within the last 24 hours
    var isRecentlyModified: Bool {
        guard let lastModified = lastModified else { return false }
        let hoursSinceModified = Date().timeIntervalSince(lastModified) / 3600
        return hoursSinceModified < 24
    }

    /// Whether the project was modified within the last 48 hours (warning threshold)
    var isModifiedRecently: Bool {
        guard let lastModified = lastModified else { return false }
        let hoursSinceModified = Date().timeIntervalSince(lastModified) / 3600
        return hoursSinceModified < 48
    }

    /// Human-readable time since last modification
    var timeSinceModified: String? {
        guard let lastModified = lastModified else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastModified, relativeTo: Date())
    }

    /// Command to regenerate the artifacts
    var regenerateCommand: String {
        type.regenerateCommand
    }
}

enum ProjectType: String, CaseIterable {
    case nodejs = "Node.js"
    case swift = "Swift"
    case rust = "Rust"
    case python = "Python"
    case java = "Java/Gradle"
    case xcode = "Xcode"
    case go = "Go"
    case ruby = "Ruby"
    case php = "PHP"
    case dotnet = ".NET"
    case cmake = "CMake"

    var icon: String {
        switch self {
        case .nodejs: return "cube.box"
        case .swift: return "swift"
        case .rust: return "gearshape.2"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .java: return "cup.and.saucer"
        case .xcode: return "hammer"
        case .go: return "figure.run"
        case .ruby: return "diamond"
        case .php: return "globe"
        case .dotnet: return "network"
        case .cmake: return "triangle"
        }
    }

    var regenerateCommand: String {
        switch self {
        case .nodejs: return "npm install"
        case .swift: return "swift build"
        case .rust: return "cargo build"
        case .python: return "pip install -r requirements.txt"
        case .java: return "./gradlew build"
        case .xcode: return "xcodebuild"
        case .go: return "go build"
        case .ruby: return "bundle install"
        case .php: return "composer install"
        case .dotnet: return "dotnet build"
        case .cmake: return "cmake -B build && cmake --build build"
        }
    }
}

actor ProjectScanner {
    static let defaultMaxDepth = DevToolsModule.defaultMaxDepth

    /// Discover projects with cleanable artifacts.
    ///
    /// Root indicators and per-type artifact directories are derived from
    /// `DevArtifactPattern.allPatterns` (via each pattern's `projectType`), so
    /// this browser can't drift from the cleanup scan's table. A directory
    /// carrying two indicator files of the same type (Podfile + *.xcodeproj) is
    /// one project; indicators of different types (package.json + Cargo.toml)
    /// keep one entry per type, as the old hand-written table did.
    func discoverProjects(
        in baseURL: URL,
        maxDepth: Int = ProjectScanner.defaultMaxDepth
    ) async -> [ProjectInfo] {
        var projects: [ProjectInfo] = []
        var seenProjects = Set<String>()
        let checker = SafetyChecker()

        guard let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        while let url = enumerator.nextObject() as? URL {
            let depth = url.pathComponents.count - baseURL.pathComponents.count
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }

            // Skip node_modules, vendor, etc.
            let name = url.lastPathComponent
            if name == "node_modules" || name == "vendor" || name == ".git" || name == "Library" {
                enumerator.skipDescendants()
                continue
            }

            guard let projectType = DevArtifactPattern.projectType(forRootIndicator: name) else { continue }

            let projectPath = url.deletingLastPathComponent()
            let projectKey = "\(projectPath.path)|\(projectType.rawValue)"
            guard !seenProjects.contains(projectKey) else { continue }

            // Find artifact directories
            var artifacts: [URL] = []
            var totalSize: Int64 = 0
            var mostRecentModification: Date?

            for artifactDir in DevArtifactPattern.artifactDirectories(for: projectType) {
                let artifactPath = projectPath.appending(path: artifactDir)
                guard FileManager.default.fileExists(atPath: artifactPath.path) else { continue }
                // Same gate scanForPatterns applies (DevToolsModule.scan): a
                // protected path must not become listable/selectable in the
                // per-project browser UI.
                guard checker.validateForScan(artifactPath, moduleID: "dev-tools").isSafe else { continue }

                artifacts.append(artifactPath)
                totalSize += (try? await DiskAnalyzer.directorySize(at: artifactPath)) ?? 0

                // Track most recent modification
                if let modDate = try? artifactPath.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    if mostRecentModification == nil || modDate > mostRecentModification! {
                        mostRecentModification = modDate
                    }
                }
            }

            // Also check the project indicator file's modification date
            if let indicatorModDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                if mostRecentModification == nil || indicatorModDate > mostRecentModification! {
                    mostRecentModification = indicatorModDate
                }
            }

            if !artifacts.isEmpty {
                seenProjects.insert(projectKey)
                var project = ProjectInfo(
                    path: projectPath,
                    type: projectType,
                    artifactPaths: artifacts
                )
                project.artifactSize = totalSize
                project.lastModified = mostRecentModification
                projects.append(project)
            }
        }

        return projects.sorted { $0.artifactSize > $1.artifactSize }
    }
}

import SwiftUI

// MARK: - Project Row

struct ProjectRow: View {
    let project: ProjectInfo
    let isSelected: Bool
    let onToggle: () -> Void
    @State private var showingRegenCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Selection checkbox
                SelectionCheckmark(isSelected: isSelected, onToggle: onToggle)

                // Type icon
                Image(systemName: project.type.icon)
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(colorFor(type: project.type))

                // Project info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(project.name)
                            .font(.body)
                            .lineLimit(1)

                        // Recently modified warning
                        if project.isRecentlyModified {
                            HStack(spacing: 2) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                Text("Active")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.15), in: Capsule())
                            .help("Modified \(project.timeSinceModified ?? "recently") - this project may be in active development")
                        } else if project.isModifiedRecently {
                            HStack(spacing: 2) {
                                Image(systemName: "clock")
                                    .font(.caption2)
                                Text("Recent")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.yellow)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.yellow.opacity(0.15), in: Capsule())
                            .help("Modified \(project.timeSinceModified ?? "recently")")
                        }
                    }

                    HStack(spacing: 8) {
                        Text(project.type.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(colorFor(type: project.type).opacity(0.2), in: Capsule())
                            .foregroundStyle(colorFor(type: project.type))

                        if let timeSince = project.timeSinceModified {
                            Text(timeSince)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                        Text(project.path.path)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }

                    Text("Rebuild: \(project.regenerateCommand)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Artifacts
                VStack(alignment: .trailing, spacing: 2) {
                    Text(project.formattedSize)
                        .font(.headline)

                    Text("\(project.artifactPaths.count) artifacts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Info button for regeneration command
                Button {
                    showingRegenCommand.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .popover(isPresented: $showingRegenCommand) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Regenerate with:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text(project.regenerateCommand)
                                .font(.system(.caption, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))

                            CopyCommandButton(command: project.regenerateCommand)
                        }
                    }
                    .padding()
                }

                // Reveal in Finder
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([project.path])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func colorFor(type: ProjectType) -> Color {
        switch type {
        case .nodejs: return .green
        case .swift: return .orange
        case .rust: return .red
        case .python: return .blue
        case .java: return .brown
        case .xcode: return .purple
        case .go: return .cyan
        case .ruby: return .red
        case .php: return .indigo
        case .dotnet: return .purple
        case .cmake: return .teal
        }
    }
}

// MARK: - Artifact Row

struct ArtifactRow: View {
    let item: CleanupItem
    let isSelected: Bool

    var body: some View {
        SelectableItemRow(isSelected: isSelected) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.orange)
                .frame(width: 24)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(item.moduleName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)

                    Text(item.path.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Text("Recreated by the owning developer tool when needed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } trailing: {
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.formattedSize)
                    .font(.headline)

                if let date = item.lastModified {
                    Text(date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Modified date unavailable")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Git Artifact Row

struct GitArtifactRow: View {
    let item: GitCleanupItem
    let isSelected: Bool
    let onToggle: () -> Void
    @State private var showingCommand = false

    var body: some View {
        SelectableItemRow(isSelected: isSelected, onToggle: onToggle) {
            Image(systemName: item.kind.icon)
                .foregroundStyle(item.kind == .worktree ? .teal : .indigo)
                .frame(width: 24)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .lineLimit(1)

                    Text(item.kind.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((item.kind == .worktree ? Color.teal : Color.indigo).opacity(0.16), in: Capsule())
                        .foregroundStyle(item.kind == .worktree ? .teal : .indigo)
                }

                HStack(spacing: 8) {
                    if let timeSince = item.timeSinceActivity {
                        Text(timeSince)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Text(item.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(
                        item.kind == .worktree
                            ? "Deletes the worktree directory"
                            : "Deletes the local branch reference"
                    )
                        .font(.caption)
                        .foregroundStyle(.orange)

                    Text((item.displayPath ?? item.repositoryPath).path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        } trailing: {
            Text(item.formattedSize)
                .font(.headline)

            Button {
                showingCommand.toggle()
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .popover(isPresented: $showingCommand) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cleanup command:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text(item.commandPreview)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))

                        CopyCommandButton(command: item.commandPreview)
                    }
                }
                .padding()
            }
        }
    }
}

// MARK: - Copy Command Button

private struct CopyCommandButton: View {
    let command: String

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(command, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy command to clipboard")
        .help("Copy to clipboard")
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        // A genuinely custom control (a tappable filter pill), so it takes the
        // raw `.glassEffect` via `glassControl` — mirroring the icon-cluster
        // pattern in `MenuBarView`. The selection state is a tint accent, not a
        // solid fill; unselected pills stay on neutral regular glass.
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? .white : .primary)
                .contentShape(Capsule())
                .glassControl(
                    in: Capsule(),
                    tint: isSelected ? MacSweepTheme.selection : nil,
                    interactive: true
                )
        }
        .buttonStyle(.plain)
    }
}

#if !SWIFT_PACKAGE
#Preview {
    DevToolsView()
        .environmentObject(AppState())
        .frame(width: 800, height: 600)
}

#endif

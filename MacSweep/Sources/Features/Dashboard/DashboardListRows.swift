import SwiftUI
import AppKit

// MARK: - List Rows

struct DashboardRowIcon: View {
    let systemName: String
    let tint: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 24, height: 24)
    }
}

struct RecommendationRow: View {
    let icon: String
    let title: String
    let detail: String
    let buttonTitle: String
    var isLoading = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            DashboardRowIcon(systemName: icon, tint: .accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 16)

            Button {
                action()
            } label: {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 48)
                } else {
                    Text(buttonTitle)
                        .frame(minWidth: 48)
                }
            }
            .glassButton()
            .disabled(isLoading || isDisabled)
        }
        .padding(.vertical, 4)
    }
}

struct SmartCareFindingRow: View {
    let finding: SmartCareFinding
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                DashboardRowIcon(
                    systemName: finding.autoCleanRecommended ? "checkmark.shield" : "doc.text.magnifyingglass",
                    tint: finding.autoCleanRecommended ? .green : .orange
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text("\(finding.itemCount) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(finding.formattedBytes)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .monospacedDigit()

                    Text(finding.autoCleanRecommended ? "Recommended" : "Review Required")
                        .font(.caption2)
                        .foregroundStyle(finding.autoCleanRecommended ? .green : .orange)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

struct SmartCareGroupSummaryRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DashboardRowIcon(systemName: icon, tint: tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct CleanupReviewGroup: Identifiable {
    let id: String
    let title: String
    let items: [CleanupItem]
    let selectedCount: Int
    let selectedBytes: Int64
    let totalBytes: Int64

    var itemIDs: Set<CleanupItem.ID> {
        Set(items.map(\.id))
    }

    var isFullySelected: Bool {
        selectedCount == items.count && !items.isEmpty
    }

    var formattedSelectedBytes: String {
        selectedBytes.formattedFileSize
    }
}

struct CleanupReviewSummaryRow: View {
    let isExpanded: Bool
    let selectedCount: Int
    let totalCount: Int
    let selectedSizeText: String
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                DashboardRowIcon(systemName: "checklist.checked", tint: .accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected for Cleanup")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                Text(selectedSizeText)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(selectedCount == 0 ? .secondary : .primary)
                    .monospacedDigit()

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Selected for cleanup")
        .accessibilityValue(summaryText)
        .help(isExpanded ? "Hide cleanup item details" : "Review cleanup item details")
    }

    private var summaryText: String {
        if selectedCount == 0 {
            return "No items selected. Expand to review \(totalCount) scan results."
        }
        return "\(selectedCount) of \(totalCount) items selected. Expand to review details."
    }
}

struct CleanupReviewBulkActionsRow: View {
    let selectedCount: Int
    let totalCount: Int
    let selectedSizeText: String
    let hasRecommendedItems: Bool
    let selectRecommended: () -> Void
    let selectAll: () -> Void
    let selectNone: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            DashboardRowIcon(systemName: "slider.horizontal.3", tint: .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(selectedCount) of \(totalCount) selected")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("Queued cleanup: \(selectedSizeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 16)

            HStack(spacing: 10) {
                Button("Recommended", action: selectRecommended)
                    .disabled(!hasRecommendedItems)

                Button("All", action: selectAll)

                Button("None", action: selectNone)
                    .disabled(selectedCount == 0)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

struct CleanupReviewGroupHeader: View {
    let group: CleanupReviewGroup
    let toggleSelection: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Spacer()
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text("\(group.selectedCount) of \(group.items.count) selected")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 16)

            Text(group.formattedSelectedBytes)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(group.selectedCount == 0 ? .secondary : .primary)
                .monospacedDigit()

            Button(group.isFullySelected ? "Clear" : "Select", action: toggleSelection)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

struct CleanupReviewItemRow: View {
    let item: CleanupItem
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 24)

                Image(systemName: item.icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(item.path.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(item.formattedSize)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .monospacedDigit()

                    if let date = item.lastModified {
                        Text(date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.displayName)
        .accessibilityValue(isSelected ? "Selected for cleanup" : "Not selected")
        .help(item.path.path)
    }
}

struct StatusMessageRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            DashboardRowIcon(systemName: icon, tint: tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SystemStatusRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    var value: String? = nil
    var valueTint: Color = .primary
    var progress: Double? = nil
    var progressTint: Color = .accentColor
    var alertLevel: MetricAlertLevel = .normal

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            DashboardRowIcon(systemName: icon, tint: tint)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if alertLevel != .normal {
                        Image(systemName: alertLevel == .critical ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(alertLevel.color)
                    }
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let progress {
                    ProgressView(value: clamped(progress))
                        .tint(progressTint)
                }
            }

            Spacer(minLength: 16)

            if let value {
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(valueTint)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

struct ScanProgressStatusView: View {
    let progress: Double
    let message: String
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)

                Text(message)
                    .font(compact ? .caption : .subheadline)
                    .lineLimit(1)

                Spacer()

                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            ProgressView(value: min(max(progress, 0), 1))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scan progress")
        .accessibilityValue("\(Int(progress * 100)) percent, \(message)")
    }
}

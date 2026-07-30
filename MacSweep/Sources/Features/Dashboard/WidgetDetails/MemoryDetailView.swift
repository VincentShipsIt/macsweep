import SwiftUI

/// Detailed Memory view shown in popover
struct MemoryDetailView: View {
    @ObservedObject var monitor: SystemMonitor
    /// Shared with CPUDetailView via the parent, so only one 5s `ps` sampling
    /// loop runs regardless of how many detail views have been opened (issue #103).
    @ObservedObject var processMonitor: ProcessMonitor
    @State private var isFreeing = false
    @State private var pulseAnimation = false
    @State private var freeRAMError: String?

    private var alertLevel: MetricAlertLevel {
        MetricThresholds.memory(usagePercent: monitor.memoryUsage.usedPercentage)
    }

    var body: some View {
        VStack(spacing: 16) {
            // Pressure indicator
            pressureIndicator

            // RAM breakdown
            ramBreakdown

            Divider()

            // Real-time graph
            graphSection

            Divider()

            // Top memory consumers
            topConsumers

            // Free up RAM button
            freeUpButton

            if let freeRAMError {
                MacSweepErrorBanner(message: freeRAMError) {
                    self.freeRAMError = nil
                }
            }
        }
        .padding()
        .task {
            await processMonitor.startMonitoring()
        }
        .onDisappear {
            // Stop the 5s ps-sampling timer when the popover closes (otherwise it
            // leaks and keeps spawning subprocesses).
            processMonitor.stopMonitoring()
        }
    }

    private var pressureIndicator: some View {
        HStack(spacing: 20) {
            // Circular indicator
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 10)

                Circle()
                    .trim(from: 0, to: monitor.memoryUsage.usedPercentage)
                    .stroke(
                        alertLevel.color,
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .criticalPulse(alertLevel, isPulsing: pulseAnimation)
                    .startCriticalPulse(alertLevel, into: $pulseAnimation)

                VStack(spacing: 2) {
                    Text("\(Int(monitor.memoryUsage.usedPercentage * 100))%")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Pressure")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 90, height: 90)

            // Stats
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(monitor.memoryUsage.formattedTotal)
                        .font(.caption)
                        .fontWeight(.medium)
                }

                HStack {
                    Text("Used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(monitor.memoryUsage.formattedUsed)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(alertLevel.color)
                }

                HStack {
                    Text("Available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(monitor.memoryUsage.formattedAvailable)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.green)
                }
            }

            // Alert badge
            AlertBadge(level: alertLevel, style: .stacked)
        }
    }

    private var ramBreakdown: some View {
        HStack(spacing: 8) {
            MemoryBar(label: "Wired", bytes: monitor.memoryUsage.wired, color: .red, total: monitor.memoryUsage.total)
            MemoryBar(label: "Active", bytes: monitor.memoryUsage.active, color: .yellow, total: monitor.memoryUsage.total)
            MemoryBar(label: "Compressed", bytes: monitor.memoryUsage.compressed, color: .orange, total: monitor.memoryUsage.total)
            MemoryBar(label: "Free", bytes: monitor.memoryUsage.free, color: .green, total: monitor.memoryUsage.total)
        }
    }

    private var graphSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Memory Usage")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Text(monitor.memoryUsage.formattedUsed)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            MetricGraph(
                data: monitor.memoryHistory,
                warningThreshold: 75,
                criticalThreshold: 90,
                color: alertLevel.color
            )
            .frame(height: 60)
            .macSweepCard(radius: 8)
        }
    }

    private var topConsumers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top Memory Consumers")
                .font(.subheadline)
                .fontWeight(.medium)

            ForEach(processMonitor.topByMemory(limit: 5)) { process in
                ProcessConsumerRow(process: process, metric: .memory)
            }

            if processMonitor.processes.isEmpty {
                Text("Loading processes...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
    }

    private var freeUpButton: some View {
        Button {
            Task {
                isFreeing = true
                defer { isFreeing = false }
                freeRAMError = nil
                do {
                    _ = try await monitor.freeUpMemory()
                } catch {
                    freeRAMError = error.localizedDescription
                }
            }
        } label: {
            if isFreeing {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            } else {
                Label("Free Up RAM", systemImage: "memorychip")
                    .frame(maxWidth: .infinity)
            }
        }
        .glassButton(prominent: true)
        .tint(alertLevel == .normal ? .blue : alertLevel.color)
        .disabled(isFreeing)
    }
}

/// Vertical bar showing memory segment
struct MemoryBar: View {
    let label: String
    let bytes: UInt64
    let color: Color
    let total: UInt64

    private var percentage: Double {
        guard total > 0 else { return 0 }
        return Double(bytes) / Double(total)
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    var body: some View {
        VStack(spacing: 4) {
            // Bar
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))

                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(height: geometry.size.height * percentage)
                }
            }
            .frame(height: 40)

            // Label
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Size
            Text(formattedSize)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity)
    }
}

#if !SWIFT_PACKAGE
#Preview {
    MemoryDetailView(monitor: SystemMonitor(), processMonitor: ProcessMonitor())
        .frame(width: 380, height: 500)
}

#endif

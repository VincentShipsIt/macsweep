import SwiftUI
import AppKit

/// Optimization view with process list and memory management
struct OptimizationView: View {
    @EnvironmentObject private var appState: AppState
    // Uses AppState.processMonitor — single shared sampler app-wide.
    @StateObject private var systemMonitor = SystemMonitor()
    @State private var selectedProcesses: Set<pid_t> = []
    @State private var showingQuitConfirmation = false
    @State private var isFreezingRAM = false
    @State private var ramResult: MaintenanceResult?
    @State private var sortOrder: RunningProcessSortOrder = .memory

    var body: some View {
        FeaturePageShell(
            title: "Optimization",
            subtitle: "Manage running processes and free up memory."
        ) {
            VStack(spacing: 0) {
                // System stats row
                systemStatsRow
                    .padding()

                // Surface the outcome of Free Up RAM (success total or the purge
                // failure) instead of silently swallowing it. (issue #88)
                if let result = ramResult {
                    ramResultBanner(result)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }

                Divider()

                // Process list
                processList

                // Footer with actions
                if !selectedProcesses.isEmpty {
                    Divider()
                    footer
                }
            }
        }
        .task {
            await appState.processMonitor.startMonitoring()
        }
        .onDisappear {
            appState.processMonitor.stopMonitoring()
        }
    }

    private var processMonitor: ProcessMonitor { appState.processMonitor }

    // MARK: - System Stats Row

    private var systemStatsRow: some View {
        OptimizationSystemStats(
            systemMonitor: systemMonitor,
            processCount: processMonitor.processes.count,
            isFreeingRAM: isFreezingRAM,
            onFreeUpRAM: { Task { await freeUpRAM() } }
        )
    }

    // MARK: - Process List

    private var processList: some View {
        VStack(spacing: 0) {
            // Sort controls
            HStack {
                Text("Running Processes")
                    .font(.headline)

                Spacer()

                Picker("Sort by", selection: $sortOrder) {
                    ForEach(RunningProcessSortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)

                Button {
                    Task { await processMonitor.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .glassButton()
                .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Process table
            List(selection: $selectedProcesses) {
                ForEach(sortedProcesses) { process in
                    ProcessRow(process: process, isSelected: selectedProcesses.contains(process.pid))
                        .tag(process.pid)
                }
            }
            .listStyle(.inset)
            .macSweepListSurface()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("\(selectedProcesses.count) processes selected")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Deselect All") {
                selectedProcesses.removeAll()
            }
            .glassButton()

            Button {
                showingQuitConfirmation = true
            } label: {
                Label("Quit Selected", systemImage: "xmark.circle")
            }
            .glassButton(prominent: true)
            .tint(.orange)
        }
        .padding()
        .confirmationDialog(
            "Quit \(selectedProcesses.count) Processes?",
            isPresented: $showingQuitConfirmation,
            titleVisibility: .visible
        ) {
            Button("Quit", role: .destructive) {
                quitSelectedProcesses()
            }
            Button("Force Quit", role: .destructive) {
                forceQuitSelectedProcesses()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Quitting processes may cause data loss if they have unsaved changes.")
        }
    }

    // MARK: - Actions

    private func freeUpRAM() async {
        isFreezingRAM = true
        defer { isFreezingRAM = false }
        ramResult = nil

        // Route through the shared MaintenanceActions.freeUpRAM() — the same
        // implementation the Dashboard maintenance card and `macsweep maintenance
        // free-ram` use — so purge failures (tool missing, non-zero exit, no admin
        // rights) surface to the user instead of being silently swallowed. The
        // previous private copy no-op'd on failure, contradicting CHANGELOG 1.0.2.
        do {
            ramResult = try await MaintenanceActions.freeUpRAM()
        } catch {
            ramResult = MaintenanceResult(success: false, message: error.localizedDescription)
        }

        await systemMonitor.refresh()
    }

    @ViewBuilder
    private func ramResultBanner(_ result: MaintenanceResult) -> some View {
        HStack {
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.success ? .green : .red)
            Text(result.message)
                .font(.caption)
            Spacer()
            Button {
                ramResult = nil
            } label: {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(
            result.success ? Color.green.opacity(0.1) : Color.red.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func quitSelectedProcesses() {
        let ownPID = getpid()
        for pid in selectedProcesses {
            guard ProcessMonitor.isSafeTerminationTarget(pid, currentPID: ownPID),
                  processMonitor.processes.contains(where: { $0.pid == pid }),
                  let app = NSRunningApplication(processIdentifier: pid) else {
                continue
            }
            app.terminate()
        }
        selectedProcesses.removeAll()

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await processMonitor.refresh()
        }
    }

    private func forceQuitSelectedProcesses() {
        let ownPID = getpid()
        for pid in selectedProcesses {
            // Never SIGKILL pid<=1 (launchd / kernel), ourselves, or a pid no
            // longer in the monitored list — selection can outlive a process and
            // pids are recycled, so a stale kill could land on an unrelated one.
            guard ProcessMonitor.isSafeTerminationTarget(pid, currentPID: ownPID),
                  processMonitor.processes.contains(where: { $0.pid == pid }) else { continue }
            kill(pid, SIGKILL)
        }
        selectedProcesses.removeAll()

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await processMonitor.refresh()
        }
    }

    // MARK: - Computed

    private var sortedProcesses: [RunningProcess] {
        processMonitor.processes.sorted(using: sortOrder)
    }

}

// ProcessMonitor and RunningProcess are defined in Core/Monitoring/ProcessMonitor.swift

// MARK: - Process Row

struct ProcessRow: View {
    let process: RunningProcess
    let isSelected: Bool

    var body: some View {
        SelectableItemRow(isSelected: isSelected) {
            // App icon
            Group {
                if let icon = process.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "app")
                        .frame(width: 24, height: 24)
                }
            }
        } content: {
            // Name
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(process.name)
                        .lineLimit(1)

                    if process.isActive {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                    }
                }

                if let bundleID = process.bundleID {
                    Text(bundleID)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        } trailing: {
            // Memory
            VStack(alignment: .trailing, spacing: 2) {
                Text(process.formattedMemory)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(memoryColor)

                Text("Memory")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 70)

            // CPU
            VStack(alignment: .trailing, spacing: 2) {
                Text(process.formattedCPU)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(cpuColor)

                Text("CPU")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 50)
        }
    }

    private var memoryColor: Color {
        if process.memoryMB > 1024 { return .red }
        if process.memoryMB > 512 { return .orange }
        return .primary
    }

    private var cpuColor: Color {
        if process.cpuPercent > 50 { return .red }
        if process.cpuPercent > 20 { return .orange }
        return .primary
    }
}

// MARK: - Supporting Views

struct MemoryStatRow: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }
}

struct CPUStatRow: View {
    let label: String
    let value: Double
    let color: Color

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)

            Text(String(format: "%.1f%%", value))
                .font(.caption)
                .fontWeight(.medium)
        }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    OptimizationView()
        .environmentObject(AppState())
        .frame(width: 800, height: 600)
}

#endif

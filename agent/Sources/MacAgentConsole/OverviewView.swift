import MacAgentCore
import SwiftUI

/// The fleet at a glance: counts, everything that needs attention, quiet Macs, version spread and
/// recent requests. Clicking a Mac anywhere here opens it.
struct OverviewView: View {
    @ObservedObject var store: ConsoleStore
    @ObservedObject var library: Library
    @Binding var selection: String?
    let now: Date

    var devices: [ConsoleStore.Device] { store.sortedDevices }
    var problems: [ConsoleStore.Device] { devices.filter { !$0.report.failures.isEmpty } }
    var quiet: [ConsoleStore.Device] { devices.filter(store.isQuiet) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Overview").font(.largeTitle.bold())
                    Spacer()
                    if let agent = library.files[.agent], let v = agent.version {
                        let stale = devices.filter { $0.report.agentVersion != v && !$0.report.agentVersion.isOlder(than: "0.3.0") }
                        Button("Update \(stale.count) Mac\(stale.count == 1 ? "" : "s") to agent \(v)") {
                            for d in stale { store.queue(.install, file: agent, for: d.id, label: "Update agent \(v)") }
                        }
                        .disabled(stale.isEmpty)
                        .help("Macs on 0.2 can't update themselves yet: reinstall those once with Add Mac.")
                    }
                }

                HStack(spacing: 12) {
                    Tile(title: "Macs", value: devices.count, colour: .accentColor, symbol: "desktopcomputer")
                    Tile(title: "All good", value: devices.count - problems.count - quiet.filter { $0.report.failures.isEmpty }.count,
                         colour: .green, symbol: "checkmark.circle.fill")
                    Tile(title: "Need attention", value: problems.count, colour: .orange, symbol: "exclamationmark.triangle.fill")
                    Tile(title: "Quiet (2h+)", value: quiet.count, colour: .secondary, symbol: "moon.zzz")
                }

                Section(title: "Needs attention", empty: problems.isEmpty ? "Nothing is failing." : nil) {
                    ForEach(problems) { d in
                        ForEach(d.report.failures, id: \.module) { f in
                            Row(action: { selection = d.id }) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                Text(d.report.computerName).fontWeight(.medium).frame(width: 190, alignment: .leading)
                                Text(f.subject == "device" ? f.module : "\(f.module) (\(f.subject))").frame(width: 190, alignment: .leading)
                                Text(f.detail).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }

                Section(title: "Quiet Macs", empty: quiet.isEmpty ? "Every Mac has reported in the last 2 hours." : nil) {
                    ForEach(quiet) { d in
                        Row(action: { selection = d.id }) {
                            Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                            Text(d.report.computerName).fontWeight(.medium).frame(width: 190, alignment: .leading)
                            Text("last seen \(relative(d.lastSeen, now))").foregroundStyle(.secondary)
                            Text(d.report.ipAddress ?? "").foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    Breakdown(title: "Agent", counts: tally { $0.agentVersion }, latest: AgentVersion.current)
                    Breakdown(title: "macOS", counts: tally { $0.macOS })
                    Breakdown(title: "Office", counts: tally { $0.officeVersion ?? "not installed" })
                }

                Section(title: "Recent requests", empty: store.actions.isEmpty ? "No requests yet. Use Check now or Re-apply on a Mac." : nil) {
                    ForEach(store.actions.sorted { $0.action.issued > $1.action.issued }.prefix(10)) { a in
                        let name = store.devices[a.action.serial]?.report.computerName ?? a.action.serial
                        Row(action: { selection = a.action.serial }) {
                            Image(systemName: a.result == nil ? "clock" : a.result!.ok ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(a.result == nil ? Color.secondary : a.result!.ok ? Color.green : Color.red)
                            Text(name).fontWeight(.medium).frame(width: 190, alignment: .leading)
                            Text(a.label).frame(width: 190, alignment: .leading)
                            Text(a.result?.detail ?? "waiting for the Mac").foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text(relative(a.action.issued, now)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func tally(_ key: (FleetReport) -> String) -> [(String, Int)] {
        Dictionary(grouping: devices.map { key($0.report) }, by: { $0 })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 > $1.0 }
    }
}

private struct Tile: View {
    let title: String
    let value: Int
    let colour: Color
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).foregroundStyle(colour).font(.callout)
            Text("\(max(value, 0))").font(.system(size: 34, weight: .semibold, design: .rounded))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

private struct Section<Content: View>: View {
    let title: String
    /// Message to show instead of rows, when there are none.
    let empty: String?
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 2) {
                if let empty {
                    Text(empty).foregroundStyle(.secondary).padding(.vertical, 4)
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Row<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) { content }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }
}

private struct Breakdown: View {
    let title: String
    let counts: [(String, Int)]
    var latest: String? = nil

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 4) {
                if counts.isEmpty { Text("–").foregroundStyle(.secondary) }
                ForEach(counts, id: \.0) { version, n in
                    HStack {
                        Text(version)
                        if let latest, version != latest {
                            Text("old").font(.caption2).foregroundStyle(.orange)
                        }
                        Spacer()
                        Text("\(n)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

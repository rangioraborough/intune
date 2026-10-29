import AppKit
import MacAgentCore
import SwiftUI

/// MacAgent Console: run on an IT Mac. Every Mac with the agent reports here every 10 minutes;
/// you see the fleet at a glance and can ask a Mac to check now or re-apply a module.
@main
struct MacAgentConsoleApp: App {
    @StateObject private var store: ConsoleStore
    @StateObject private var library: Library
    private let server: FleetServer

    init() {
        let store = ConsoleStore()
        let library = Library()
        _store = StateObject(wrappedValue: store)
        _library = StateObject(wrappedValue: library)
        server = FleetServer(store: store, library: library)
        server.start()
    }

    var body: some Scene {
        WindowGroup("MacAgent Console") {
            FleetView(store: store, library: library).frame(minWidth: 900, minHeight: 560)
        }
    }
}

struct FleetView: View {
    @ObservedObject var store: ConsoleStore
    @ObservedObject var library: Library
    @State private var showAddMac = false
    @State private var selection: String? = FleetView.overview
    static let overview = "__overview__"
    @State private var showSetup = false
    @State private var filter = Filter.all
    @State private var now = Date()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    enum Filter: String, CaseIterable { case all = "All", problems = "Problems", quiet = "Quiet" }

    var shown: [ConsoleStore.Device] {
        store.sortedDevices.filter {
            switch filter {
            case .all: return true
            case .problems: return !$0.report.failures.isEmpty
            case .quiet: return store.isQuiet($0)
            }
        }
    }

    @ToolbarContentBuilder
    var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { f in Text(f.rawValue).tag(f) }
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem(placement: .automatic) {
            Button { showAddMac = true } label: { Label("Add Mac", systemImage: "plus") }
        }
        ToolbarItem(placement: .automatic) {
            Button { showSetup = true } label: { Label("Setup", systemImage: "gearshape") }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Overview", systemImage: "square.grid.2x2").tag(FleetView.overview)
                Section("Macs") {
                    ForEach(shown) { d in
                        DeviceRow(device: d, quiet: store.isQuiet(d), now: now, latest: library.files[.agent]?.version).tag(d.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 320)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(store.devices.count) Macs · \(store.devices.values.filter { !$0.report.failures.isEmpty }.count) with problems")
                    Text(store.serverStatus).foregroundStyle(.secondary)
                }
                .font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            if selection == nil || selection == FleetView.overview {
                OverviewView(store: store, library: library, selection: $selection, now: now)
            } else if let s = selection, let d = store.devices[s] {
                DeviceDetail(store: store, library: library, device: d, now: now)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "desktopcomputer").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Select a Mac").font(.title3)
                    if store.devices.isEmpty {
                        Text("No Macs have reported yet. Open Setup to connect them.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar { toolbarItems }
        .sheet(isPresented: $showSetup) { SetupSheet(store: store, library: library) }
        .sheet(isPresented: $showAddMac) { AddMacSheet(library: library) }
        .onReceive(tick) { now = $0 }
    }
}

struct DeviceRow: View {
    let device: ConsoleStore.Device
    let quiet: Bool
    let now: Date
    var latest: String?

    var body: some View {
        let r = device.report
        HStack(spacing: 10) {
            Image(systemName: quiet ? "moon.zzz" : r.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(quiet ? Color.secondary : r.failures.isEmpty ? Color.green : Color.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(r.computerName).fontWeight(.medium)
                    let old = latest.map { r.agentVersion.isOlder(than: $0) } ?? false
                    Text(r.agentVersion)
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill((old ? Color.orange : Color.secondary).opacity(0.18)))
                        .foregroundStyle(old ? Color.orange : Color.secondary)
                        .help(old ? "Older than the agent in Setup (\(latest ?? "")). Use Update." : "Agent version")
                }
                Text([r.consoleUser ?? "nobody logged in", r.ipAddress, relative(device.lastSeen, now)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct DeviceDetail: View {
    @ObservedObject var store: ConsoleStore
    @ObservedObject var library: Library
    let device: ConsoleStore.Device
    let now: Date

    var body: some View {
        let r = device.report
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.computerName).font(.title2.bold())
                        Text("\(r.model) · macOS \(r.macOS) · \(r.serial)").foregroundStyle(.secondary)
                        Text("Agent \(r.agentVersion) · config \(r.configVersion.map(String.init) ?? "–") · Office \(r.officeVersion ?? "–")")
                            .foregroundStyle(.secondary)
                        Text("\(r.consoleUser.map { "Logged in: \($0)" } ?? "Nobody logged in") · \(r.ipAddress ?? "no IP") · reported \(relative(device.lastSeen, now))")
                            .foregroundStyle(store.isQuiet(device) ? .orange : .secondary)
                    }
                    Spacer()
                    Button("Check now") { store.queue(.run, for: r.serial, label: "Check now") }
                    Menu("Update…") {
                        ForEach([FleetAction.Target.agent, .site, .config], id: \.self) { t in
                            if let f = library.files[t] {
                                Button("\(t.title) \(f.version ?? "")") {
                                    store.queue(.install, file: f, for: r.serial, label: "Update \(t.title.lowercased()) \(f.version ?? "")")
                                }
                            } else {
                                Text("\(t.title): not set up (Setup)")
                            }
                        }
                    }
                    .fixedSize()
                    .disabled(r.agentVersion.isOlder(than: "0.3.0"))
                    .help(r.agentVersion.isOlder(than: "0.3.0") ? "This Mac's agent is too old to update itself. Use Add Mac to reinstall it once." : "")
                    Menu("Re-apply…") {
                        ForEach(modules, id: \.self) { m in
                            Button(m) { store.queue(.reapply, module: m, for: r.serial, label: "Re-apply \(m)") }
                        }
                    }
                    .fixedSize()
                }

                let history = store.actions(for: r.serial)
                if !history.isEmpty {
                    GroupBox("Requests") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(history.prefix(8)) { a in
                                HStack {
                                    Image(systemName: a.result == nil ? "clock" : a.result!.ok ? "checkmark.circle" : "xmark.circle")
                                        .foregroundStyle(a.result == nil ? Color.secondary : a.result!.ok ? Color.green : Color.red)
                                    Text(a.label)
                                    Text(a.result?.detail ?? "waiting for the Mac (instant if it’s awake)")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(relative(a.action.issued, now)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                ForEach(subjects(r), id: \.self) { subject in
                    GroupBox(subject == "device" ? "This Mac" : subject) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(r.states.filter { $0.subject == subject }.sorted { $0.module < $1.module }, id: \.module) { s in
                                HStack(alignment: .firstTextBaseline) {
                                    Image(systemName: symbol(s.result)).foregroundStyle(colour(s.result)).frame(width: 16)
                                    Text(s.module).frame(width: 140, alignment: .leading)
                                    Text(s.detail).foregroundStyle(.secondary).lineLimit(2)
                                    Spacer()
                                    Text(relative(s.lastRun, now)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Button("Forget this Mac", role: .destructive) { store.forget(r.serial) }
                    .font(.caption)
            }
            .padding(20)
        }
    }

    var modules: [String] { ModuleRegistry.all.map(\.id).filter { $0 != "legacy-cleanup" } }

    func subjects(_ r: FleetReport) -> [String] {
        let all = Set(r.states.map(\.subject))
        return (all.contains("device") ? ["device"] : []) + all.subtracting(["device"]).sorted()
    }

    func symbol(_ result: String) -> String {
        switch result {
        case "fail": return "exclamationmark.triangle.fill"
        case "waiting": return "clock"
        case "drift": return "arrow.uturn.backward.circle"
        default: return "checkmark.circle.fill"
        }
    }

    func colour(_ result: String) -> Color {
        switch result {
        case "fail": return .orange
        case "waiting": return .secondary
        case "drift": return .blue
        default: return .green
        }
    }
}

struct SetupSheet: View {
    @ObservedObject var store: ConsoleStore
    @ObservedObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect Macs to this console").font(.headline)
            Text("Add this to the MacAgent config in Intune (the Preference file). Use an address this Mac keeps: give it a DHCP reservation. Macs report every 10 minutes.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Console URL", text: $url)
            ScrollView {
                Text(store.configSnippet(url: url)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 170)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            Text("Keep the keys file safe: ~/Library/Application Support/MacAgent Console/keys.json. Anyone with it can send requests to the Macs.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Files for Add Mac and Update").font(.headline)
            ForEach([FleetAction.Target.agent, .site, .config], id: \.self) { t in
                HStack {
                    Text(t.title).frame(width: 90, alignment: .leading)
                    Text(library.files[t].map { "\($0.name)  ·  \($0.version ?? "")" } ?? "not set")
                        .foregroundStyle(library.files[t] == nil ? .orange : .secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = []
                        panel.directoryURL = URL(fileURLWithPath: library.path(t)).deletingLastPathComponent()
                        if panel.runModal() == .OK, let url = panel.url { library.setPath(t, url.path) }
                    }
                }
            }
            Button("Reload files") { library.reload() }.font(.caption)
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.configSnippet(url: url), forType: .string)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            if url.isEmpty {
                let ip = ["en0", "en1"].lazy.compactMap { SystemCommandRunner().run("/usr/sbin/ipconfig", ["getifaddr", $0]).trimmedOutput.nonEmpty }.first
                url = "http://\(ip ?? "this-mac"):\(ConsoleStore.port)"
            }
        }
    }
}

func relative(_ date: Date, _ now: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: date, relativeTo: now)
}

extension FleetAction.Target {
    var title: String {
        switch self {
        case .agent: return "Agent"
        case .site: return "Site files"
        case .config: return "Config"
        }
    }
}

/// Install MacAgent on a Mac over SSH (or reinstall one that's too old to update itself).
struct AddMacSheet: View {
    @ObservedObject var library: Library
    @StateObject private var installer = RemoteInstaller()
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var user = ""
    @State private var password = InstallPassword.load() ?? ""
    @State private var remember = true

    var ready: Bool {
        !host.isEmpty && !user.isEmpty && !password.isEmpty && library.files.count == 3 && !installer.running
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install MacAgent on a Mac").font(.headline)
            Text("Needs Remote Login on (System Settings > General > Sharing). Log in as the Mac's user, e.g. joeblogs. Also reinstalls a Mac that's too old to update itself.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading) {
                GridRow { Text("IP address"); TextField("10.46.0.12", text: $host) }
                GridRow { Text("Username"); TextField("joeblogs", text: $user) }
                GridRow { Text("Password"); SecureField("", text: $password) }
                GridRow { Text(""); Toggle("Remember password as the default", isOn: $remember) }
            }
            if library.files.count < 3 {
                Text("Choose the agent, site and config files in Setup first.").foregroundStyle(.orange)
            } else {
                Text(["agent", "site", "config"].compactMap { t in
                    library.files[FleetAction.Target(rawValue: t)!].map { "\($0.target.title) \($0.version ?? "")" }
                }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(installer.log.isEmpty ? " " : installer.log)
                    .font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 170).padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            HStack {
                if installer.finished == true { Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                if installer.finished == false { Label("Failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                Button("Forget old key") {
                    _ = SystemCommandRunner().run("/usr/bin/ssh-keygen", ["-R", host])
                    installer.log += "Forgot the saved SSH key for \(host).\n"
                }
                .disabled(host.isEmpty).help("Use when a Mac was wiped and SSH says its key changed")
                Spacer()
                Button("Close") { dismiss() }.disabled(installer.running)
                Button(installer.running ? "Installing…" : "Install") {
                    if remember { InstallPassword.save(password) }
                    installer.install(host: host.trimmingCharacters(in: .whitespaces), user: user.trimmingCharacters(in: .whitespaces),
                                      password: password, agent: library.files[.agent]!.path,
                                      site: library.files[.site]!.path, config: library.files[.config]!.path)
                }
                .keyboardShortcut(.defaultAction).disabled(!ready)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

import AppKit
import MacAgentCore
import SwiftUI

/// /Applications/MacAgent.app: a menu bar icon for every user. The menu stays short (headline,
/// Status…, links, help); the Status window holds the checks, Check again and printer details.
@main
struct MacAgentMenuApp: App {
    @StateObject private var model = StatusModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.symbol)
        }

        Window("MacAgent", id: "status") {
            StatusWindow(model: model)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class StatusModel: ObservableObject {
    @Published private(set) var report = StatusReport(states: [])
    @Published private(set) var menu: MenuBarConfig?
    @Published private(set) var printerDetailsAvailable = false
    @Published private(set) var checking = false
    @Published var notice: String?
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        report = StatusReport.load(home: FileManager.default.homeDirectoryForCurrentUser)
        if case .loaded(let config, _) = ConfigLoader(paths: .device()).load(updateCache: false) {
            menu = config.menuBar
        }
        printerDetailsAvailable = PrinterDetails.presetsInstalled(prefs: UserPreferences())
    }

    var symbol: String {
        if checking { return "arrow.triangle.2.circlepath" }
        if report.rows.isEmpty { return "clock" }
        return report.healthy ? "checkmark.shield" : "exclamationmark.triangle.fill"
    }

    var lastChecked: String {
        guard let date = report.lastChecked else { return "Not checked yet" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Last checked " + f.localizedString(for: date, relativeTo: Date())
    }

    /// Ask the daemon for a device run (via the trigger folder) and run this user's session now.
    func checkNow() {
        guard !checking else { return }
        checking = true
        try? RunTrigger.request(user: NSUserName())
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: AgentIdentity.cliPath)
            p.arguments = ["run", "--scope", "session"]
            try? p.run()
            p.waitUntilExit()
            try? await Task.sleep(nanoseconds: 20_000_000_000)   // give the device run time to finish
            await MainActor.run {
                self.checking = false
                self.refresh()
            }
        }
    }

    func open(_ urlString: String, with app: String? = nil) {
        guard let url = URL(string: urlString) else { return }
        if let app, case let appURL = URL(fileURLWithPath: "/Applications/\(app).app"),
           FileManager.default.fileExists(atPath: appURL.path) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func copyDiagnostics() {
        refresh()
        let text = report.diagnostics(computerName: Host.current().localizedName ?? "this Mac",
                                      user: NSUserName(), version: AgentVersion.current)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = "Diagnostics copied. Paste them into your message to IT."
    }

    func savePrinterDetails(name: String, code: String) {
        do {
            let count = try PrinterDetails.apply(name: name, code: code, prefs: UserPreferences())
            notice = "Printer details saved to \(count) preset\(count == 1 ? "" : "s")."
        } catch {
            notice = "Couldn't save printer details: \((error as? ModuleError)?.message ?? "\(error)")"
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: StatusModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.report.headline)
        Button("Status…") {
            openWindow(id: "status")
            NSApp.activate(ignoringOtherApps: true)
        }

        if let items = model.menu?.items, !items.isEmpty {
            Divider()
            ForEach(items, id: \.title) { item in
                Button {
                    model.open(item.url, with: item.app)
                } label: {
                    if let symbol = item.symbol { Label(item.title, systemImage: symbol) } else { Text(item.title) }
                }
            }
        }
        if let title = model.menu?.helpTitle, let url = model.menu?.helpURL {
            Divider()
            Button(title) { model.open(url) }
        }
    }
}

struct StatusWindow: View {
    @ObservedObject var model: StatusModel
    @State private var showPrinterDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: model.symbol)
                    .font(.title)
                    .foregroundStyle(model.report.healthy ? Color.green : Color.orange)
                VStack(alignment: .leading) {
                    Text(model.report.headline).font(.headline)
                    Text(model.lastChecked).font(.caption).foregroundStyle(.secondary)
                }
            }

            if !model.report.rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.report.rows, id: \.module) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: Self.symbol(row.result))
                                .foregroundStyle(Self.colour(row.result))
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                Text(row.detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            }

            if let notice = model.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                Button(model.checking ? "Checking…" : "Check again") { model.checkNow() }
                    .disabled(model.checking)
                if model.printerDetailsAvailable {
                    Button("Printer details…") { showPrinterDetails = true }
                }
                Spacer()
                Button("Copy diagnostics") { model.copyDiagnostics() }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { model.refresh() }
        .sheet(isPresented: $showPrinterDetails) {
            PrinterDetailsSheet { name, code in model.savePrinterDetails(name: name, code: code) }
        }
    }

    static func symbol(_ r: RunResult) -> String {
        switch r {
        case .ok, .changed, .drift: return "checkmark.circle.fill"
        case .waiting: return "clock"
        case .fail: return "exclamationmark.triangle.fill"
        }
    }

    static func colour(_ r: RunResult) -> Color {
        switch r {
        case .ok, .changed, .drift: return .green
        case .waiting: return .secondary
        case .fail: return .orange
        }
    }
}

struct PrinterDetailsSheet: View {
    let save: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Printer details").font(.headline)
            Text("Used by the copiers for secure print and accounting. Leave a field empty to keep what's there.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name shown on the copier", text: $name)
            TextField("Accounting code", text: $code)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(name.trimmingCharacters(in: .whitespaces), code.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          && code.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

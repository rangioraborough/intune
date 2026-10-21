import AppKit
import MacAgentCore
import SwiftUI

/// Menu bar app shown to every user: status at a glance, Check now, help, and links from config.
@main
struct MacAgentMenuApp: App {
    @StateObject private var model = StatusModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.symbol)
        }
    }
}

@MainActor
final class StatusModel: ObservableObject {
    @Published private(set) var report = StatusReport(states: [])
    @Published private(set) var menu: MenuBarConfig?
    @Published private(set) var checking = false
    private var timer: Timer?

    nonisolated static let agent = "/Library/Application Support/MacAgent/MacAgent.app/Contents/MacOS/macagent"

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
            p.executableURL = URL(fileURLWithPath: Self.agent)
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
    }
}

struct MenuContent: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        Text(model.report.headline)
        Text(model.lastChecked)

        if !model.report.rows.isEmpty {
            Divider()
            ForEach(model.report.rows, id: \.module) { row in
                Menu("\(Self.mark(row.result))  \(row.title)") {
                    Text(row.detail)
                }
            }
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

        Divider()
        Button(model.checking ? "Checking…" : "Check now") { model.checkNow() }
            .disabled(model.checking)
        if let title = model.menu?.helpTitle, let url = model.menu?.helpURL {
            Button(title) { model.open(url) }
        }
        Button("Copy diagnostics") { model.copyDiagnostics() }
        Divider()
        Text("MacAgent \(AgentVersion.current)")
    }

    static func mark(_ result: RunResult) -> String {
        switch result {
        case .ok, .changed, .drift: return "✓"
        case .waiting: return "…"
        case .fail: return "⚠︎"
        }
    }
}

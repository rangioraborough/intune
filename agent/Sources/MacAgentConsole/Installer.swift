import Foundation

/// Installs (or reinstalls) MacAgent on a Mac over SSH, the way it was done by hand: copy the site
/// pkg, config and agent pkg, then install them as root. Needs Remote Login on the target and that
/// user's password (they're an admin on these Macs). The password is passed to `expect` through
/// its environment, never on a command line, and isn't stored here.
@MainActor
final class RemoteInstaller: ObservableObject {
    @Published var log = ""
    @Published var running = false
    @Published var finished: Bool?   // nil while running / not started; true = success

    func install(host: String, user: String, password: String, agent: String, site: String, config: String) {
        running = true
        finished = nil
        log = "Connecting to \(user)@\(host)…\n"
        let script = Self.expectScript
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
            p.arguments = ["-c", script, host, user, agent, site, config]
            p.environment = ["MACAGENT_PW": password, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { h in
                let text = String(decoding: h.availableData, as: UTF8.self)
                    .replacingOccurrences(of: password, with: "••••")
                if !text.isEmpty { Task { @MainActor in self.log += text } }
            }
            do { try p.run() } catch {
                await MainActor.run { self.log += "Couldn't start: \(error.localizedDescription)\n"; self.running = false; self.finished = false }
                return
            }
            p.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            let ok = p.terminationStatus == 0
            await MainActor.run {
                self.log += ok ? "\nDone. The Mac will report to the console within a few minutes.\n"
                               : "\nInstall failed (exit \(p.terminationStatus)). See above.\n"
                self.running = false
                self.finished = ok
            }
        }
    }

    /// expect: scp the three files, then one ssh session that installs them with sudo.
    static let expectScript = #"""
    set timeout 900
    lassign $argv host user agent site config
    set pw $env(MACAGENT_PW)
    proc auth {} {
        global pw
        expect {
            "assword:" { send -- "$pw\r"; exp_continue }
            -re "REMOTE HOST IDENTIFICATION HAS CHANGED" { puts "\nThis Mac's SSH key changed (it was probably wiped). Use 'Forget old key' and try again."; exit 3 }
            -re "Connection refused|Operation timed out|No route to host" { puts "\nCan't reach it. Is Remote Login on (System Settings > General > Sharing)?"; exit 4 }
            -re "Permission denied" { puts "\nWrong username or password."; exit 5 }
            eof
        }
    }
    set opts {-o StrictHostKeyChecking=accept-new -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 -o ConnectTimeout=10}
    puts "Copying packages and config…"
    eval spawn scp $opts [list $agent $site $config] [list "$user@$host:/tmp/"]
    auth
    lassign [wait] pid spawnid os_error status
    if {$status != 0} { puts "\nCopy failed."; exit 6 }
    set a [file tail $agent]; set s [file tail $site]; set c [file tail $config]
    set cmd "sudo -S -p 'MACAGENT-SUDO:' sh -c 'installer -pkg \"/tmp/$s\" -target / && mkdir -p \"/Library/Application Support/MacAgent\" && cp \"/tmp/$c\" \"/Library/Application Support/MacAgent/config-cache.plist\" && installer -pkg \"/tmp/$a\" -target / ; r=\$?; rm -f \"/tmp/$a\" \"/tmp/$s\" \"/tmp/$c\"; exit \$r'"
    puts "Installing…"
    eval spawn ssh $opts [list "$user@$host" $cmd]
    expect {
        "MACAGENT-SUDO:" { send -- "$pw\r"; exp_continue }
        "assword:" { send -- "$pw\r"; exp_continue }
        -re "Permission denied" { puts "\nWrong username or password."; exit 5 }
        -re "Sorry, try again|not in the sudoers" { puts "\nThat account can't use sudo (it must be an admin)."; exit 8 }
        timeout { puts "\nTimed out."; exit 7 }
        eof
    }
    lassign [wait] pid spawnid os_error status
    exit $status
    """#
}

# Plan v2: a managed Mac agent, delivered and configured entirely by Intune

Status: proposal, 2026-10-21. Supersedes [mac-agent-plan.md](mac-agent-plan.md) (rev 2).
Progress and later decisions (naming, menu bar, cleanup): [agent-progress.md](agent-progress.md).

What changed from rev 2:

- **No Intune scripts at all.** The agent ships as an Intune **macOS app (PKG)**. The current 11
  script policies are retired once their modules are proven.
- **Config lives in Intune**, as a Preference file. Nothing is fetched from GitHub at runtime.
- **One universal admin password**, delivered as a password *hash*, never as plain text.
- **Reporting is local**: a log file and `rbsctl status` on each Mac. No console reporting.

---

## 1. Why

On 2026-10-21 a freshly enrolled MacBook Air (`MBA-Annabellesimpson`, macOS 26.6) showed every
known weakness of the current approach in one go:

| Script | What happened | Intune reported |
|---|---|---|
| ConfigureFinder | Every `defaults write` failed: `Could not write domain com.apple.finder` | Success |
| SetDefaultBrowser | Write failed, and Chrome wasn't installed yet; script exits 0, so never retried | Success |
| SetWallpaper | `osascript` → Finder timed out 3 times (`-1712`), then worked | Failure, then Success |
| ConfigureDock | Built with 3 of 11 apps because it ran before InstallApps finished | Success |
| ConfigurePrinters | Agent failed to hand over the script (`stdInWriteFailure`) 3 times | Success after retry |

These share one root cause: the Intune agent runs everything as **root, outside the user's
session**, on its own schedule, with no ordering between scripts and no way to tell "succeeded"
from "exited 0". Patching each script doesn't change that. Running our own code, in the right
context, does.

---

## 2. What sits in Intune

Exactly two objects, plus the existing app assignments.

| Intune object | Type | Contents |
|---|---|---|
| **RBS Mac Agent** | macOS app (PKG), required, all Macs | The signed agent package (§3) |
| **RBS Agent Config** | Configuration profile → Preference file, domain `com.rangiorab.macagent` | All fleet config (§4) |

Separate Preference files can be assigned to different groups (for example staff Macs and
student or lab Macs). The agent doesn't care which one it got; it applies what's there.

The Preference file is a configuration profile, which rev 2 ruled out. That rule was about
settings being split between profiles and code. Here the profile carries only the agent's
input. Every setting is still applied, checked and logged by the agent, so there is still one
place that owns "what should this Mac look like".

### Upgrading the agent

Upload a new PKG to the same Intune app with a higher version. Intune installs it on its next
check-in. The package's postinstall reloads the LaunchDaemon and LaunchAgent. Nothing else is
involved: no self-update code, no download, no version pinning.

### Lessons carried over from the current PKG apps

The Apeos PKG and Company Portal both caused Intune retry storms (see TODO.md). Both were
failure cases: a PKG that couldn't install without Rosetta, and a wrong detection rule. To stay
out of that:

- The agent PKG has **no dependencies** (no Rosetta, no network) and must install cleanly on a
  bare Mac.
- Detection uses the agent's own bundle ID and version. Phase 1 confirms Intune actually detects
  it before anything else is built on top.
- Anything that *can* fail (app downloads, the Apeos driver) runs later inside the agent, where a
  failure is logged and retried on the next tick, not reported to Intune as a failed install.

---

## 3. The agent

One signed, notarised package:

```
com.rangiorab.macagent.pkg
├── /Library/Application Support/RBS/RBS Agent.app     bundle (for Intune detection) containing rbsctl
├── /usr/local/bin/rbsctl                              symlink into the bundle
├── /Library/Application Support/RBS/resources/        wallpaper, avatars, printer preset plist,
│                                                      FUJIFILM PS Plug-in pkg, Installomator.sh
├── /Applications/Update Printer Details.app           real signed app
├── /Applications/Classview.app                        real signed app
├── /Library/LaunchDaemons/com.rangiorab.macagent.plist        root: device work
└── /Library/LaunchAgents/com.rangiorab.macagent.user.plist    every user, in their session
```

Written in **Swift**: a single universal binary with no runtime to bundle, native access to
preferences, plists, Open Directory and SQLite, and signable and notarisable.

### Scopes

Every module declares one.

| Scope | Runs as | Runs when | Used for |
|---|---|---|---|
| `device` | root (LaunchDaemon) | boot, every 4h, and when the config profile changes | apps, printer queues, device name, admin account, MAU |
| `each-user` | root, looping over local accounts | with each device run | avatar, printer preset plists, default printer |
| `session` | **the user (LaunchAgent), inside their login session** | every login, every user | Dock, Finder, wallpaper, default browser |

`session` fixes both of the worst problems at once:

- **No more "Could not write domain"**: the agent *is* the user, so plain `defaults write` works.
  No `sudo -u`, no `launchctl asuser`.
- **New users get configured**: a LaunchAgent starts for every user at every login. A teacher
  logging into an existing Mac for the first time is simply a user with no state yet.

### Ordering

Session modules that depend on device work wait for it. For example, `dock` won't run until
`apps` has finished at least once (success or logged failure). This removes the race that left
today's Dock with 3 apps.

### Enforcement

Each module declares how hard it holds its setting:

- `enforce: once`: apply once per user per config version, then leave it alone so the teacher
  can change it. Proposed for Dock, Finder, wallpaper and default browser.
- `enforce: always`: re-check every run and re-apply if something changed it, logging that it
  had to. Proposed for MAU, printer queues, device name, admin account and apps.

### State

`/Library/Application Support/RBS/state.db` (SQLite), one row per (module, subject), holding:
the config hash it applied, last run, result, duration, error text, agent version. Session
modules write `~/Library/Application Support/RBS/state.json`, which the root daemon reads on its
next run so `rbsctl status` can show every user.

Re-application is driven by a **hash of each module's config**, not by hand-bumped numbers.
Change the Dock app list in Intune and every Mac re-applies the Dock once, automatically.
`dockversion`, `CLASSVIEW_ICON_VERSION` and the fingerprint files all go away.

---

## 4. Config: the Intune Preference file

The agent reads its config through the managed preferences domain `com.rangiorab.macagent`.
macOS installs it at `/Library/Managed Preferences/com.rangiorab.macagent.plist`.

Example shape (abridged):

```xml
<dict>
  <key>ConfigVersion</key>        <integer>1</integer>
  <key>DeviceNamePrefix</key>     <dict><key>MacBook Air</key><string>MBA</string> ...</dict>

  <key>AdminAccount</key>
  <dict>
    <key>Username</key>           <string>itadmin</string>
    <key>FullName</key>           <string>IT Admin</string>
    <key>Hidden</key>             <true/>
    <key>PasswordHash</key>       <string>(output of rbsctl hash-password)</string>
  </dict>

  <key>Printers</key>
  <array>
    <dict><key>Name</key><string>Ruru_Copier</string>
          <key>URI</key><string>lpd://10.69.192.23/</string>
          <key>Default</key><true/></dict>
    ...
  </array>

  <key>Apps</key>                 <array><string>googlechrome</string><string>vlc</string> ...</array>
  <key>DockApps</key>             <array><string>/Applications/Google Chrome.app</string> ...</array>
  <key>Finder</key>               <dict> ... </dict>
  <key>Wallpaper</key>            <string>RBS-Background.jpg</string>
</dict>
```

- **Edit in Intune, nowhere else.** There is no copy in git. The Intune console is the source of
  truth; export the plist before each change if you want a history.
- **Small values only.** Large files (wallpaper, printer preset plist, Apeos driver) ship inside
  the package and the config refers to them by name.
- **Validation before applying.** If the plist is missing a required key or has the wrong type,
  the agent logs exactly what's wrong and keeps using the last good config it cached. A typo in
  Intune can't half-configure the fleet.
- **No config, no action.** On a Mac where the profile hasn't arrived yet, the agent logs that it
  is waiting and does nothing.

---

## 5. The admin password

One universal password for the hidden `itadmin` account, set from Intune, changeable from Intune.

**The plain-text password never goes into Intune or onto a Mac.** Files in
`/Library/Managed Preferences` are expected to be readable by any local user (to be confirmed in
Phase 1). So the config holds the password in the form macOS itself stores it: a salted
PBKDF2-SHA512 hash, the same data macOS keeps in the account's `ShadowHashData`.

- `rbsctl hash-password` (run on any Mac with the agent) prompts for the password and prints the
  value to paste into `AdminAccount.PasswordHash`.
- The `admin-account` module creates the account if it doesn't exist, hides it, and writes that
  hash directly onto it. `enforce: always`, so a changed hash in Intune rolls out to every Mac
  at its next run.
- Anyone who copies the hash could only use it to guess the password offline. Use a long
  passphrase (four or more random words) and that isn't practical.
- An account set up this way has no Secure Token, so it cannot unlock FileVault. The current
  account is the same.
- Change it when anyone who knows it leaves. One password opens every Mac.

**Teacher accounting codes are untouched by this.** They're entered by each teacher in Update
Printer Details and stored only in that user's preferences. They never go into the config or the
log.

---

## 6. Reporting: local only

Nothing is sent off the Mac.

| Where | What |
|---|---|
| `/Library/Logs/RBS/agent.log` | Device and each-user runs: one line per module per run with result, duration, error |
| `~/Library/Logs/RBS/session.log` | That user's session modules |
| `rbsctl status` | Summary for this Mac and all its users: what's applied, when, what failed, what drifted |

Example `agent.log` lines:

```
2026-10-21T13:04:27+13:00 device  admin-account   ok      0.4s  config=3f9a
2026-10-21T13:05:23+13:00 device  apps            ok     58.1s  installed=googlechrome
2026-10-21T13:06:02+13:00 device  printer-queues  fail    2.0s  Tui_Copier: lpadmin exit 1 (no route to host)
2026-10-21T17:04:11+13:00 device  mau-disable     drift   0.2s  LaunchAgent restored by Office update, removed again
```

- Logs rotate daily and keep 14 days.
- `drift` means an `enforce: always` module found its setting changed and put it back. A Mac that
  drifts every run is worth a look.
- Lines never contain the password hash or accounting codes.

The tradeoff: finding out the state of the fleet means visiting each Mac (or SSH). If that
becomes a problem later, the log format is ready to be collected, and adding a sender is a
contained change.

---

## 7. What happens to each current script

| Script | Becomes |
|---|---|
| DeviceRename.sh | `device-name`, `device`, always |
| CreateAdminAccount.sh | `admin-account`, `device`, always, password from hash (§5) |
| InstallApps.sh + InstallApps-worker.sh | `apps`, `device`, via bundled Installomator (checks each vendor's signature) |
| InstallCompanyPortal.sh | Folded into `apps` (label `companyportal`) |
| DisableMAU.sh | `mau-disable`, `device`, always |
| ConfigurePrinters.sh | `printer-queues` (`device`, always) + `printer-presets` (`each-user`, once) |
| UpdatePrinterUserDetails.sh | Update Printer Details.app, one signed copy in the package |
| SetUserAvatar.sh | `avatar`, `each-user` |
| ConfigureDock.sh | `dock`, `session`, once, waits for `apps` |
| ConfigureFinder.sh | `finder`, `session`, once |
| SetWallpaper.sh | `wallpaper`, `session`, once. Written directly, no AppleScript to Finder (see note) |
| SetDefaultBrowser.sh | `default-browser`, `session`, once. Raises Chrome's own "make default" prompt at first login and logs the user's answer. macOS doesn't allow setting it silently |
| CapturePrinterPresets.sh | `rbsctl dev capture-presets` |
| ResetForRetest.sh | `rbsctl state reset` |

**Wallpaper note:** rev 2 proposed writing `desktoppicture.db`. That file is believed to be unused
since macOS 14, which keeps wallpaper settings in
`~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`. Phase 3 confirms the right
method on macOS 26 before building it.

**Rule for every module: no Apple Events to other apps.** Without a PPPC profile, `tell application
"Finder"` raises a permission prompt and fails if it's ignored. That's what broke SetWallpaper.
Use `defaults`, `dscl`/Open Directory, `lpadmin`, `installer`, `scutil` and direct file writes.

---

## 8. Phases

The fleet is live. Each old script policy keeps running until its replacement is proven on a test
Mac, then that one policy is unassigned.

**Phase 0: urgent fix, now.** The hidden admin account has a blank password on every Mac. Until
the agent replaces it, put the universal password into the CreateAdminAccount script **in the
Intune console only** (not in this repo) and make it reset the password on Macs where the account
already exists. Make this repo private: it currently publishes the copier IPs and the admin
account name.

**Phase 1: skeleton and delivery (2–3 days).** Swift package, config loader with validation,
state DB, logging, LaunchDaemon and LaunchAgent, signed and notarised PKG. Ships with
`device-name` only. Upload to Intune as a macOS app on one test Mac. Confirm:
- Intune detects the install, and a new version uploaded to Intune replaces it.
- The Preference file arrives and the agent reads it.
- Who can read `/Library/Managed Preferences` (decides §5).

**Phase 2: device modules (3–4 days).** `apps`, `printer-queues`, `admin-account`,
`mau-disable`. Run alongside the old scripts on the test Mac, compare, then retire the old
policies one at a time.

**Phase 3: per-user modules (3–4 days).** `dock`, `finder`, `wallpaper`, `default-browser`,
`avatar`, `printer-presets`.
**Acceptance test: on an already-configured Mac, create a brand-new user, log in, and confirm the
Dock, Finder, wallpaper, avatar and printer presets all appear with nothing else touched.** That
isn't possible today.

**Phase 4: real app bundles (1–2 days).** Update Printer Details and Classview as signed apps in
the package. Removes the heredoc copy inside ConfigurePrinters and the icon-cache flushing.

**Phase 5: cleanup (1 day).** Unassign the last script policies, move `scripts/macOS/` to
`legacy/`, write a one-page runbook (how to change config, upgrade the agent, read the logs).

Roughly two to three weeks part-time. End state in Intune: one app, one Preference file, zero
scripts.

---

## 9. Decisions still needed

1. **Apple Developer ID.** Needed to sign and notarise the package and the two bundled apps.
   Does the school have one, or should one be set up?
2. **`enforce: once` vs `always` per module.** The proposal is in §3. This decides which teacher
   changes stick.
3. **Separate configs for student or lab Macs?** If yes, define the groups before Phase 2.
4. **Where packages are built.** The agent's source code still lives in this repo. Either GitHub
   Actions builds and signs each release (the signing certificate stored as a repo secret), or an
   IT Mac with Xcode does. Either way, the finished PKG is uploaded to Intune by hand.

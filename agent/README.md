# MacAgent

A Swift agent that configures school Macs. Intune delivers it as a macOS app (PKG) and configures it
with a Preference file. Design: [docs/planv2.md](../docs/planv2.md).

## Build

```sh
./build.sh                          # test, build universal, sign, package → dist/MacAgent-<ver>.pkg
APP_IDENTITY=- ./build.sh           # ad-hoc signed, for local testing only
NOTARY_PROFILE=macagent ./build.sh  # also notarise and staple
```

Needs the command line tools (Swift 6), a `Developer ID Application` certificate for the app and a
`Developer ID Installer` certificate for the pkg. Bump `AgentVersion.current` in
[Sources/MacAgentCore/Paths.swift](Sources/MacAgentCore/Paths.swift) for each release; Intune detects
upgrades by bundle ID `nz.co.myers.macagent` and that version.

## Configure

Upload a Preference file profile in Intune with domain `nz.co.myers.macagent`.
[config/example.plist](config/example.plist) documents every key. Check a file before uploading:

```sh
macagent config --config example.plist
```

If the managed config is missing or invalid, the agent keeps using the last good one and logs why.

## On a Mac

| | |
|---|---|
| `sudo macagent status` | what's applied, for whom, when, what failed |
| `sudo macagent run --scope device --dry-run` | what would change (as the user: `macagent run --scope session --dry-run`) |
| `sudo macagent run --scope device [--module ID] [--force]` | run now |
| `sudo macagent state reset [ID]` | forget a module so it re-applies (e.g. `device-name` to re-pick the user) |
| `macagent desktop` | this user's wallpaper and default browser |
| `macagent hash-password` | make the `AdminAccount.PasswordHash` value |
| `/Library/Logs/MacAgent/agent.log` | device runs, one line per module per run, 14 days kept |
| `~/Library/Logs/MacAgent/session.log` | that user's session runs |

The daemon runs at boot, every 4 hours and whenever a profile changes. The session agent runs at each
login as that user.

## Modules

| ID | Scope | Enforce | Replaces |
|---|---|---|---|
| `device-name` | device | always | DeviceRename.sh. Names the Mac from `DeviceName.Template`, locked to the first eligible user |
| `preferences` | session | per entry | ConfigureFinder.sh, and any other per-user `defaults write`. `Preferences` lists domains → keys; `Enforce` once or always; optional `Restart` |
| `dock` | session | module | ConfigureDock.sh. Built once per user from `Dock.Apps`; apps installed later are slotted in; user changes are kept |
| `admin-account` | device | always | CreateAdminAccount.sh. Hidden admin with the password from `AdminAccount.PasswordHash` (`macagent hash-password`). Refuses to touch an account with a Secure Token |
| `mau-disable` | device | always | DisableMAU.sh. Reports drift when an Office update puts AutoUpdate back |
| `apps` | device | always | InstallApps*.sh, InstallCompanyPortal.sh. Rosetta, Installomator labels (install if missing, never update), site packages by receipt |
| `web-apps` | device | always | Classview from InstallApps. Link apps in /Applications from `WebApps` |
| `printer-queues` | device | always | ConfigurePrinters.sh step 1. Never re-runs lpadmin on a correct queue |
| `avatar` | device | module | SetUserAvatar.sh. Once per user, including users who haven't logged in |
| `wallpaper` | session | once | SetWallpaper.sh. Through NSWorkspace, no AppleScript |
| `printer-presets` | session | once | ConfigurePrinters.sh step 2, plus the user's default printer if they have none |
| `default-browser` | session | once | SetDefaultBrowser.sh. macOS asks the user; unanswered means ask again next login |
| `legacy-cleanup` | device | module | Archives each old script's leftovers once its replacement has applied |

Session modules don't run for `ExcludedUsers`. After any device run that changed something, the daemon
kickstarts the logged-in user's session run, so e.g. the Dock picks up newly installed apps straight away.

## Site resources

Files a school's config refers to (wallpaper, avatars, icons, printer presets, driver packages) ship in
a separate package so the agent stays identical everywhere. `site/<school>/files.txt` lists them;
`site/build-site.sh rbs` builds `MacAgent Site - RBS-<ver>.pkg`, which installs to
`/Library/Application Support/MacAgent/Site/`. Upload it to Intune as a second macOS app.

## Menu bar app

`/Applications/MacAgent.app` is the menu bar app (the `macagent` CLI is inside it, and Installomator in
its Resources). LaunchAgent `nz.co.myers.macagent.menu` runs it for every user and restarts it if quit.

The menu: headline, **Status…**, links from `MenuBar.Items` (optionally opened in a named app), and
`MenuBar.HelpTitle`/`HelpURL`. The Status window lists each area with its detail, and has
**Check again**, **Printer details…** (name and accounting code into the Apeos presets) and
**Copy diagnostics**.

Check again runs the user's session modules and asks the daemon for a device run by writing a file in
`/Library/Application Support/MacAgent/Trigger` (sticky, world-writable; launchd allows one run a minute,
and a press inside that minute is queued, not dropped).

Users can switch off background items (the agent and the menu) in System Settings → General → Login
Items. Only a Managed Login Items profile in Intune prevents that.

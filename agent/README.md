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

Session modules don't run for `ExcludedUsers`. The session agent also re-runs when something is added
to `/Applications`, so the Dock picks up new apps without waiting for the next login.

## Menu bar app

`MacAgent Menu.app` runs for every user (LaunchAgent `nz.co.myers.macagent.menu`, restarted if quit).
It shows:

- a headline ("This Mac is set up" / "1 thing needs attention") and when the Mac last checked
- each area with ✓ / … / ⚠︎, with the detail in a submenu
- links from `MenuBar.Items`, optionally opened in a specific app
- **Check now**: runs the user's session modules straight away, and asks the daemon for a device run
  by writing a file in `/Library/Application Support/MacAgent/Trigger` (sticky, world-writable;
  launchd allows one run a minute, and a press inside that minute is queued, not dropped)
- `MenuBar.HelpTitle` / `HelpURL` (mailto:, https:, tel:) and **Copy diagnostics**, which puts a status
  summary on the clipboard for a support ticket

Users can switch off background items (the agent and the menu) in System Settings → General → Login
Items. Only a Managed Login Items profile in Intune prevents that.

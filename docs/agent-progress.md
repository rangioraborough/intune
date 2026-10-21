# MacAgent: progress and next steps

Last updated 2026-10-21. Design: [planv2.md](planv2.md). Code and usage: [agent/README.md](../agent/README.md).

## Decisions made

| Topic | Decision |
|---|---|
| Delivery | Intune macOS app (PKG). No Intune scripts once migration is done |
| Config | Intune Preference file, domain `nz.co.myers.macagent`. No GitHub at runtime |
| Naming | `nz.co.myers.macagent` (universal, not school-specific), CLI `macagent` |
| Site files (wallpaper, presets, avatars) | Separate per-school resources pkg (not built yet) |
| Admin password | One universal password, stored in config as a PBKDF2 hash, never plain text |
| Reporting | Local only: `/Library/Logs/MacAgent/agent.log`, `~/Library/Logs/MacAgent/session.log`, `macagent status` |
| Signing | Tony's Developer ID (team 25ZM6S7AH2). Installer cert still to be created |
| Builds | `agent/build.sh` on this Mac (command line tools only, no Xcode) |
| Device name | Template in config (`{model}-{user}`), locked to the first eligible user |
| Dock | Built once per user with what's installed; late apps slotted in; user changes kept |
| Existing users | Get Dock/Finder setup once at next login |
| Finder | Generic `Preferences` module (domain → keys), not a Finder-specific one |
| Old script leftovers | Archived/removed only after the replacing module has applied; `/Library/RBS` kept until wallpaper/avatar modules exist |
| Menu bar | Shown to everyone. Status, Check now, help, custom links; printer details later |

## Built and tested

37 unit tests pass. Installed by hand on Annabelle's MacBook Air (`MBA-Annabellesimpson`,
10.69.193.1, macOS 26.6, arm64), with the example config placed in the agent's fallback cache.
Verified on the Mac, not just from logs:

- `device-name`: name kept, locked to annabellesimpson
- `dock`: all 11 apps in order, recents off
- `preferences`: every Finder setting applied (these all failed under the old script)
- `legacy-cleanup`: DeviceRename, ConfigureDock, ConfigureFinder archived to `/Library/Logs/MacAgent/legacy/`
- Menu bar app running; Check now triggers a device run (throttled to one a minute, queued not dropped)

**Not yet checked:** what the menu bar icon and menu look like on screen.

## Open actions for Tony

1. Look at the menu bar on Annabelle's Mac and note changes.
2. In Intune, unassign ConfigureDock, ConfigureFinder and DeviceRename for her Mac. Their markers are
   gone, so ConfigureDock would rebuild her Dock if it runs again (the agent logs this as drift).
3. Decide on a Managed Login Items profile. Without it users can switch off the agent and menu in
   System Settings → Login Items.
4. Create a **Developer ID Installer** certificate; `build.sh` makes an unsigned pkg until then.
5. Set up notarisation: `xcrun notarytool store-credentials macagent --apple-id … --team-id 25ZM6S7AH2`.
6. Replace the placeholder `MenuBar` help address and portal link in `agent/config/example.plist`.

## Next modules, in order

1. `admin-account` (device): universal password from a hash, plus `macagent hash-password`.
   Fixes the blank-password `itadmin` account. The old CreateAdminAccount.sh still sets an empty password.
2. `wallpaper` (session): no AppleScript. First check how macOS 26 stores wallpaper
   (believed to be `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`).
3. `apps` (device): Installomator bundled in the pkg, with signature checks.
4. Per-school resources pkg, then `printer-queues`, `printer-presets`, and Update Printer Details in the menu bar.
5. `avatar`, `default-browser`, `mau-disable`.
6. Phase 1 checks still outstanding: Intune detects the pkg and upgrades it; a real Preference file
   arrives and is readable; who can read `/Library/Managed Preferences`.

## Known loose ends

- The Finder Desktop keys copied from the old script (`IconSize`, `FontSize`, `LabelOnBottom`, ...)
  sit at the top level of `DesktopViewSettings`. Finder actually uses
  `DesktopViewSettings.IconViewSettings`, so they probably have no visible effect. Fix when checking on screen.
- `chflags nohidden ~/Library` from ConfigureFinder isn't ported (not a preference).
- `planv2.md` still says `com.rangiorab.macagent` and `desktoppicture.db`; this file and the README are current.

## Testing on a Mac

Install by hand: copy `agent/dist/MacAgent-<ver>.pkg` and a config plist over, then as root:
put the config at `/Library/Application Support/MacAgent/config-cache.plist` (don't write into
`/Library/Managed Preferences`, which Intune owns) and `installer -pkg … -target /`.
Then `sudo macagent status`, and `cat /Library/Logs/MacAgent/agent.log`.

# MacAgent: progress and next steps

Last updated 2026-10-28. Design: [planv2.md](planv2.md). Code and usage: [agent/README.md](../agent/README.md).

## Decisions made

| Topic | Decision |
|---|---|
| Delivery | Intune macOS app (PKG): `MacAgent-<ver>.pkg`, plus a per-school `MacAgent Site - <SCHOOL>.pkg`. No Intune scripts once migration is done |
| App | One `/Applications/MacAgent.app`: menu bar app, with the `macagent` CLI and Installomator inside |
| Config | Intune Preference file, domain `nz.co.myers.macagent`. No GitHub at runtime |
| Naming | `nz.co.myers.macagent` (universal, not school-specific) |
| Site files | `site/<school>/files.txt` → `site/build-site.sh` → installs to `/Library/Application Support/MacAgent/Site` |
| Admin password | One universal password, config holds a PBKDF2 hash; existing accounts are reset to it |
| Reporting | Local only: `/Library/Logs/MacAgent/agent.log`, `~/Library/Logs/MacAgent/session.log`, `macagent status` |
| Signing | Tony's Developer ID (team 25ZM6S7AH2). Installer cert still to be created |
| Builds | `agent/build.sh` on this Mac (command line tools only, no Xcode) |
| Device name | Template in config (`{model}-{user}`), locked to the first eligible user |
| Dock | Built once per user with what's installed; late apps slotted in; user changes kept |
| Finder | Generic `Preferences` module (domain → keys) |
| Apps | Installomator v10.9 (pinned, `agent/vendor/`), install if missing, never update |
| Wallpaper / avatars | Once per user |
| Default browser | macOS asks the user once; no answer means ask again next login |
| Old script leftovers | Archived once each replacement has applied |
| Menu bar | Shown to everyone. Menu: headline, Status…, links, help. Window: checks, Check again, Printer details, Copy diagnostics |

## Built and tested

58 unit tests pass. 0.2.0 plus the RBS site package installed by hand on Annabelle's MacBook Air
(`MBA-Annabellesimpson`, 10.69.193.1, macOS 26.6, arm64). Verified on the Mac, not just from logs:

- Dock (11 apps), Finder settings, device name: unchanged since 0.1.0, still correct
- Wallpaper: points at the site copy (checked with `macagent desktop`)
- Default browser: the macOS prompt appeared from the agent and was accepted; Chrome is default
- Avatars: Annabelle and itadmin use the site images
- Classview: rebuilt as the agent's web app, opens in Chrome
- Printers, apps, Rosetta, Apeos driver, MAU: already in place, modules report ok
- Old leftovers archived for every script except CreateAdminAccount; `/Library/RBS` and the old
  Update Printer Details.app removed
- Old Intune scripts ran again on 27 Oct and the agent flagged it as drift: they're still assigned

Also installed on Kelly's Mac mini (`MacMini-KellyTaylor`, 10.69.193.8, macOS 27.0, arm64), a fresh
enrollment with nothing from Intune yet: in about 2 minutes the agent installed Rosetta, the Apeos driver,
Chrome, Drive, VLC, Zoom, built Classview, added the 4 copiers, set picture, wallpaper, Finder, Dock and
presets. When Intune then installed Office, the Dock picked up Word/Excel/PowerPoint and MAU drift was
fixed. Fixes from that test: the daemon now kickstarts the user's session run after device changes
(WatchPaths on /Applications doesn't fire on macOS 27); an unanswered browser prompt waits 12h before
asking again; names use the account's full name (`MacMini-KellyTaylor`) and Mac mini is `MacMini`.

**Not yet checked:** the new menu and Status window on screen; Printer details… end to end;
admin-account on a real Mac (needs the hash).

## Admin account

The real config is `agent/config/rbs.plist` (git-ignored; upload this one to Intune). It has the
hash for the universal password; `example.plist` keeps a placeholder. The account is now `admin`
(was `itadmin`); `AdminAccount.RemoveAccounts` deletes the old `itadmin`. Verified on Kelly's Mac:
created, hidden, admin group, no Secure Token, real SSH login works with the password, picture set.
Annabelle's Mac (offline at the time) still has the old blank-password `itadmin` until it gets this build.

## Open actions for Tony

1. (done) Admin password hash is in `rbs.plist`.
2. Look at the menu and Status window on Annabelle's Mac; try Printer details….
3. In Intune, unassign the old scripts for her Mac (all of them except CreateAdminAccount until the
   hash is in). They ran again on 27 Oct.
4. Decide on a Managed Login Items profile (stops users switching the agent off).
5. Create a **Developer ID Installer** certificate; set up notarisation
   (`xcrun notarytool store-credentials macagent --apple-id … --team-id 25ZM6S7AH2`).
6. Replace the placeholder `MenuBar` help address and portal link in `agent/config/example.plist`.

Notes from Kelly's Mac:
- Intune took ~30 min after enrollment to send anything; then the Intune agent arrived, so **the old
  scripts will run on new Macs too unless they're unassigned for them**.
- Classroom isn't in the agent's app list (App Store app via Intune/VPP); Word/Excel/PowerPoint come from Intune.
- Its time zone was US Pacific (Setup Assistant skipped location).
- Company Portal removed from the config (no Conditional Access / compliance in use).
- Annabelle's Mac still needs the new build to pick up `MBA-AnnabelleSimpson` (offline at the time).

## Next steps

1. Test admin-account on Annabelle's Mac once the hash arrives (`dscl . -authonly itadmin` to verify).
2. Phase 1 checks: upload both pkgs + a Preference file to Intune for a test group; confirm Intune
   detects/upgrades the pkg, the profile arrives, and who can read `/Library/Managed Preferences`.
3. Then roll out by group, unassigning each old script as its module takes over.

## Known loose ends

- Finder Desktop keys copied from the old script (`IconSize`, `FontSize`, ...) sit at the top level of
  `DesktopViewSettings`; Finder uses `DesktopViewSettings.IconViewSettings`. Check on screen.
- `chflags nohidden ~/Library` from ConfigureFinder isn't ported (not a preference).
- `planv2.md` still says `com.rangiorab.macagent` and `desktoppicture.db`; this file and the README are current.
- `/usr/bin/python3`, `strings` and other developer tools on school Macs are stubs: running them pops an
  "install developer tools" dialog on the user's screen. Use only built-in tools (cat, grep, plutil, dscl).
- Login Items: Microsoft Outlook / Teams / Corporation stay listed while the apps are installed; only
  their switches matter. Microsoft Corporation (Intune agent + Office licensing) must stay on.
- Teams opening at login after a sign-in: undecided (quit-at-login fallback, or wait for a sign-in sample).

## Testing on a Mac

Build: `agent/build.sh` (`APP_IDENTITY=-` for ad-hoc) and `site/build-site.sh rbs`. Copy both pkgs and
a config plist over; as root put the config at `/Library/Application Support/MacAgent/config-cache.plist`
(never write into `/Library/Managed Preferences`, which Intune owns), install the site pkg then the agent.
Check with `sudo macagent status`, `macagent desktop`, and the logs.


## Update 2026-10-30: console, 0.3.x, where we're up to

**MacAgent Console** (`agent/Sources/MacAgentConsole`, build with `agent/build-console.sh`) runs on the IT
iMac (`iMac-Sysadmin`, currently Wi-Fi `10.46.0.93` - needs a DHCP reservation, then update `Console.URL`
in rbs.plist). Keys: `~/Library/Application Support/MacAgent Console/keys.json` (back it up).
- Overview page, per-Mac detail, version badges, Check now, Re-apply, Update (agent / site / config),
  Add Mac (SSH install; default password in the iMac Keychain), Setup (config snippet + package library).
- Macs report every 10 min (`nz.co.myers.macagent.report`) and, from 0.3.3, keep a long-poll open
  (`nz.co.myers.macagent.listen`) so console requests apply within seconds. Requests are Ed25519-signed
  by the console; reports and downloads are HMAC-signed with the fleet key.
- Updates are checksum-only for now (user's choice); switch to signed-only once the Developer ID
  Installer certificate exists.

**Agent versions:** 0.3.3 is current (dist/MacAgent-0.3.3.pkg). Each release: bump
`AgentVersion.current`, `./build.sh`, then Overview > "Update N Macs".
- Sue (10.46.0.66): 0.3.3, instant requests working - try Check now first thing Monday.
- Alison, Dee, Jasmine, Marie, Rachel, Yuta: 0.3.x. Use the console's Update to bring them to 0.3.3.
- Annabelle (now 10.46.0.69), Emma (10.46.0.82), Kylee (10.46.0.12): still 0.2.0; reinstall once with
  Add Mac (0.2.0 can't take console updates).
- Kelly: IP unknown, on an old build.

**Printing:** one-sided everywhere (presets, last-used, queue default and, from 0.3.2, the queue PPD's
*Default lines). printer-presets re-applies once per user on 0.3.2+.

**Other session (intune-34)** worked in parallel on printers/menu bar/Chrome first-run/Bonjour names;
its changes are in this commit too. Chrome first-run is off in the config (macOS 27 blocks it).

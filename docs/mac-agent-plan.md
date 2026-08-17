# Plan: turn the Intune script collection into a managed Mac agent

Status: proposal, 2026-08-17. Supersedes the ad-hoc structure described in [TODO.md](../TODO.md).

---

## 1. Why change

Three problems, each traceable to a specific thing in the repo today.

**"We lose track of what's been done."**
Every script invents its own state model. [ConfigureDock.sh](../scripts/macOS/ConfigureDock.sh)
uses a hand-bumped `dockversion` marker *plus* an installed-app fingerprint file.
[InstallApps-worker.sh](../scripts/macOS/InstallApps-worker.sh) uses a hand-bumped
`CLASSVIEW_ICON_VERSION` stamped next to the icon. [ConfigurePrinters.sh](../scripts/macOS/ConfigurePrinters.sh)
uses a sentinel preset name. Others use nothing at all. All of it is per-device, on-device,
in 14 separate log files — so the only way to know the fleet's state is to walk up to a Mac.
TODO item B is the consequence: a device sat `0x87D30143` for four days and nobody noticed.

**"If we add new users, the script won't rerun."**
Six scripts configure *the console user* (`stat -f "%Su" /dev/console`) from a *device-level*
root context, and record completion in a *device-level* marker. So the second teacher to log
into a Mac gets nothing — the marker says done. Worse, the mechanism itself is fragile: root
`sudo -u user defaults write` can't reach the user's `cfprefsd`, which is exactly the bug the
`launchctl asuser` workaround in ConfigureDock was added to fix, and which
[ConfigureFinder.sh](../scripts/macOS/ConfigureFinder.sh) and
[SetWallpaper.sh](../scripts/macOS/SetWallpaper.sh) still have.

**"The scripts aren't always the best."**
1,891 lines with no tests and heavy duplication — the entire
[UpdatePrinterUserDetails.sh](../scripts/macOS/UpdatePrinterUserDetails.sh) is pasted a second
time as a heredoc inside ConfigurePrinters.sh, and the two will drift. A 74 KB base64 plist is
embedded mid-script. Apps are downloaded and copied into `/Applications` with **no signature
check of any kind**. And because scripts are pasted into the Intune console by hand, the repo
is not actually the source of truth — TODO item A is an open reminder to go paste the current
launcher.

The launcher/LaunchDaemon split in [InstallApps.sh](../scripts/macOS/InstallApps.sh) already
proves the direction: the way out of the Intune agent's constraints is **one long-lived process
we own**. This plan generalises that from one script to the whole estate.

---

## 2. Decide this first: build vs. buy vs. profiles

Before writing code, two things should shrink the amount of code.

### 2a. Is a dedicated Apple MDM cheaper than maintaining an agent?

Everything below is buildable and I'd enjoy building it, but it is a bespoke fleet-management
agent maintained by one person. **Mosyle Manager** has a genuinely free tier for schools and
**Jamf School** is inexpensive per-seat in education; both do app catalogues, per-user
configuration at login, and fleet reporting out of the box. Intune can stay as the compliance /
Entra identity layer alongside either.

If a two-hour trial of Mosyle covers the app installs, the dock, and the reporting, take it —
the remaining custom work collapses to the Apeos printer stack alone. **Do this evaluation
before Phase 1.** The rest of this plan assumes Intune stays the only MDM.

### 2b. Move settings out of code and into Configuration Profiles

A profile applies to every user automatically, at login, forever, with no state tracking and no
code. Anything that can be a profile should not be a module:

| Currently | Move to |
|---|---|
| [DisableMAU.sh](../scripts/macOS/DisableMAU.sh) | `com.microsoft.autoupdate2` profile. Deleting MAU's LaunchAgent doesn't stick — Office updates put it back. A profile does stick. |
| [SetWallpaper.sh](../scripts/macOS/SetWallpaper.sh) | `com.apple.desktop` payload (`overridePicturePath`). The current `osascript` under `sudo -u` no longer works reliably on recent macOS. |
| Most of [ConfigureFinder.sh](../scripts/macOS/ConfigureFinder.sh) | `com.apple.finder` profile — but note a profile *enforces* and greys out the setting. Only move the ones you're happy to lock. |
| [SetDefaultBrowser.sh](../scripts/macOS/SetDefaultBrowser.sh) | **Delete it.** It writes `com.apple.launchservices.secure`, which macOS has ignored for several releases — the malformed dict (duplicate `LSHandlerRoleAll` keys) is moot because the write is a no-op. macOS offers no silent way to set the default browser; it requires a user click. Either accept the prompt or drop the requirement. |

This is a real reduction: four scripts gone before the agent exists.

---

## 3. Target architecture

One signed package, installed once, containing one binary and its resources.

```
com.rangiorab.macagent.pkg
├── /usr/local/rbs/rbsctl                     universal binary
├── /usr/local/rbs/resources/                 wallpaper, avatars, PPD presets, Apeos pkg
├── /usr/local/rbs/vendor/Installomator.sh    pinned + checksummed
├── /Applications/Update Printer Details.app  real bundle, built in CI
├── /Applications/Classview.app               real bundle, built in CI
├── /Library/LaunchDaemons/com.rangiorab.macagent.plist    root, device work
└── /Library/LaunchAgents/com.rangiorab.macagent.user.plist  per-user, session work
```

### The three scopes — this is the fix for the new-user problem

Every module declares one:

| Scope | Runs as | Runs when | Replaces |
|---|---|---|---|
| `device` | root, via LaunchDaemon | boot + every 4h | device rename, printer queues, app installs |
| `each-user` | root, iterating every local account | with the device tick | avatar, preset plists, default-queue seeding — the `for home in /Users/*` loops that already exist in ConfigurePrinters |
| `session` | **the user, via LaunchAgent, inside their GUI session** | **every login, every user** | dock, Finder, wallpaper |

`session` is the whole answer to "new users don't get configured". A LaunchAgent in
`/Library/LaunchAgents` starts in *every* user's session at *every* login, as that user. State
is keyed per-UID, so a new teacher on an existing Mac is simply a user with no state yet. As a
bonus the `launchctl asuser` / `sudo -u` dance disappears entirely — the agent is already in
the session, so `defaults write` just works.

### State and idempotence

One record per `(module, scope, subject)` in SQLite at
`/Library/Application Support/RBS/state.db`, holding: desired-state hash, last run, outcome,
duration, error text, agent version. Session-scope agents write
`~/Library/Application Support/RBS/state.json`; the root daemon merges those on its tick, so
root can report on all users without any XPC helper.

Re-application is driven by **a hash of the module's config**, not by a hand-bumped integer.
Change the dock app list in the manifest and every device re-applies once, automatically —
`dockversion="3"` and `CLASSVIEW_ICON_VERSION="3"` and the fingerprint file all go away.

The "configure once, then hand control to the user" behaviour that ConfigureDock and
ConfigurePrinters implement in different ad-hoc ways becomes one declared field:

```yaml
- id: dock
  scope: session
  enforce: once        # apply once per user per config-hash, then never touch again
  config:
    apps: [ ... ]

- id: printer-queues
  scope: device
  enforce: always      # converge every tick
```

### Config

The manifest ships **inside the signed package**, not fetched at runtime. Today the fleet's
control plane is `raw.githubusercontent.com/rangioraborough/intune/main` on a **public repo** —
any push to `main`, or any compromise of a maintainer account, is root on every school Mac,
with no signature check anywhere in the chain. Embedding the config and shipping it signed
closes that. Config changes are cheap because CI builds the package. An optional
`/Library/Application Support/RBS/overrides.yaml` covers one-off local testing.

### Delivery and self-update

- **One** Intune shell-script policy remains, permanently: ~15 lines that check the installed
  version against the pinned release, and if it differs, hand off to a LaunchDaemon to install.
  It exits in under a second, so the agent's ~10s kill never touches it. This is the
  [InstallApps.sh](../scripts/macOS/InstallApps.sh) trick, generalised and made permanent.
- Everything else ships in the package. **No more pasting scripts into the console** — which
  retires TODO item A as a category, not just as a task.
- The package is verified by Team ID before install, and by SHA-256 against the release.

### Reporting — the answer to "we lose track"

- `rbsctl report --format=intune` emits one line, wired up as an **Intune macOS Custom
  Attribute**. It then shows per-device in the console and exports to CSV, with zero extra
  infrastructure:
  `v1.4.2 ok=13 fail=1 stale=0 users=2 last=2026-08-17T09:14Z fail=printer-queues`
- Later, optionally: POST the full JSON to a Google Apps Script endpoint backed by a Sheet, with
  a daily time-trigger that emails on any failure or any device silent for 48h. That closes
  TODO item B properly — for the agent's own work *and* for Intune app-install status.

### CLI

```
rbsctl status                    what's applied here, for whom, when, what failed
rbsctl run [--module X] [--scope S] [--dry-run] [--force]
rbsctl state reset [X]           replaces ResetForRetest.sh
rbsctl logs [X]
rbsctl report [--format intune|json]
rbsctl dev capture-presets       replaces CapturePrinterPresets.sh
```

### Language

**Swift.** One universal binary, no runtime to bundle (macOS hasn't shipped Python since 12.3),
signable and notarizable, native plist and preferences access, and it's what the Mac admin world
writes tooling in (Nudge, swiftDialog). It also lets *Update Printer Details* become a real
signed app instead of a bundle assembled by `cat` heredoc at runtime.

Go is the reasonable alternative if authoring speed matters more than Mac-nativeness — a static
binary, faster to write, but you'll shell out for everything plist-related and it's a less
familiar choice for whoever maintains this next.

Either way most module bodies stay recognisable: they shell out to `lpadmin`, `installer`,
`scutil`, `dscl` exactly as today. The existing bash knowledge is not thrown away.

---

## 4. What happens to each existing script

| Script | Today | Becomes |
|---|---|---|
| [DeviceRename.sh](../scripts/macOS/DeviceRename.sh) | Works | Module, `device`, `enforce: always` |
| [CreateAdminAccount.sh](../scripts/macOS/CreateAdminAccount.sh) | **Blank password** | Module + per-device random password, escrowed. See §7 |
| [InstallCompanyPortal.sh](../scripts/macOS/InstallCompanyPortal.sh) | curl + installer | Installomator label `companyportal` |
| [InstallApps.sh](../scripts/macOS/InstallApps.sh) | Launcher hack | Deleted — the agent *is* the daemon |
| [InstallApps-worker.sh](../scripts/macOS/InstallApps-worker.sh) | 287 lines, unverified downloads | Module `apps`, `device`; Chrome/VLC/Drive/Zoom/Company Portal via Installomator |
| [DisableMAU.sh](../scripts/macOS/DisableMAU.sh) | Reverts on Office update | Configuration Profile |
| [ConfigureFinder.sh](../scripts/macOS/ConfigureFinder.sh) | Root `sudo -u`, unreliable | Profile for enforced settings; module `session` for the rest |
| [ConfigureDock.sh](../scripts/macOS/ConfigureDock.sh) | Markers + fingerprint + `asuser` | Module, `session`, `enforce: once` |
| [SetWallpaper.sh](../scripts/macOS/SetWallpaper.sh) | `osascript` as root, breaks | Profile payload; image ships in the pkg |
| [SetUserAvatar.sh](../scripts/macOS/SetUserAvatar.sh) | Console user only | Module, `each-user` — covers users who haven't logged in yet |
| [SetDefaultBrowser.sh](../scripts/macOS/SetDefaultBrowser.sh) | No-op on modern macOS | **Delete** |
| [ConfigurePrinters.sh](../scripts/macOS/ConfigurePrinters.sh) | 363 lines, 74 KB inline base64, duplicated app | Split: `printer-queues` (`device`) + `printer-presets` (`each-user`). Preset plist becomes a resource file |
| [UpdatePrinterUserDetails.sh](../scripts/macOS/UpdatePrinterUserDetails.sh) | Duplicated inside ConfigurePrinters | One real signed app, built in CI, one copy |
| [CapturePrinterPresets.sh](../scripts/macOS/CapturePrinterPresets.sh) | Admin helper | `rbsctl dev capture-presets` |
| [ResetForRetest.sh](../scripts/macOS/ResetForRetest.sh) | Test helper | `rbsctl state reset` |
| Classview icon versioning | Manual stamps + icon-cache flush | App bundle ships in the pkg; no runtime fetch, no version stamp |

Net: 14 scripts and 1,891 lines → roughly 8 modules, 4 profiles, 2 deletions.

---

## 5. Phased migration

The fleet is live. Nothing is switched off until its replacement is proven on a test Mac.

**Phase 0 — Safety fixes now, in bash (half a day).**
Don't wait for the agent. Fix the blank admin password (§7), add Team ID verification to the
existing downloads, and delete SetDefaultBrowser.

**Phase 1 — Skeleton and pipeline (2–3 days).** The riskiest part is delivery, so prove it first
with the most boring module.
Swift package; state DB; manifest loader; LaunchDaemon + LaunchAgent; `pkgbuild` + sign +
notarize in GitHub Actions → GitHub Release; the 15-line Intune bootstrap; `rbsctl report`
wired to an Intune custom attribute. Ship with **DeviceRename only**. Success = push a commit,
watch a test Mac pick up the new version by itself and report in.

**Phase 2 — Device modules (3–4 days).**
`apps` via Installomator (this is where the unverified-download risk dies), `printer-queues`,
`local-admin`. Run in parallel with the existing Intune scripts on one test Mac, compare, then
disable the old policies one at a time.

**Phase 3 — Per-user modules (2–3 days).** The payoff phase.
`dock` and `finder` at `session` scope, `avatar` and `printer-presets` at `each-user`.
**Acceptance test: create a brand-new user on an already-configured Mac, log in, and confirm the
dock, Finder, avatar and printer presets all appear without touching the device.** That test is
the thing that isn't possible today.

**Phase 4 — Real app bundles (1–2 days).**
Build *Update Printer Details* and *Classview* as proper signed bundles in CI. Deletes the
heredoc duplication and the whole icon-cache flushing routine.

**Phase 5 — Reporting, cleanup, docs (2 days).**
Failure alerting (§3), retire all remaining Intune script policies, move
`FUJIFILM PS Plug-in Installer.pkg` (5.2 MB) and the wallpaper (2.5 MB) out of git into Release
assets, write the runbook, freeze `scripts/macOS/` under `legacy/`.

Roughly **two to three weeks part-time**, and usable from the end of Phase 1.

---

## 6. Repo layout

```
Sources/rbsctl/            CLI entry, scheduler, state store, reporter
Sources/RBSModules/        one file per module, each check() + apply()
Tests/                     unit tests over a filesystem/command abstraction
Resources/                 wallpaper, avatars, preset plist, Apeos pkg (from Release, not git)
Apps/UpdatePrinterDetails/ real Xcode/SwiftPM target
Apps/Classview/
packaging/                 pkgbuild, launchd plists, postinstall, notarization
vendor/Installomator.sh    pinned version + checksum
config/manifest.yaml       the fleet's desired state
profiles/                  the .mobileconfig payloads from §2b
.github/workflows/         build → test → sign → notarize → release
legacy/scripts/macOS/      frozen originals, deleted after Phase 5
docs/
```

Testing is the quiet win: `check()` and `apply()` behind a command abstraction are unit
testable, which none of the current 1,891 lines are. Plus `rbsctl run --dry-run` for a real
device, and `rbsctl state reset` to re-test.

---

## 7. Security issues to fix regardless of this plan

1. **`ADMIN_PASSWORD=""` in [CreateAdminAccount.sh](../scripts/macOS/CreateAdminAccount.sh).**
   A hidden local admin account with a blank password on every school Mac. Fix in Phase 0 with a
   per-device random password escrowed somewhere you can retrieve it (Intune's macOS LAPS support
   if your tenant has it; otherwise escrow via the reporting channel). Separately, an account
   created this way generally has no Secure Token, so it can't unlock FileVault — worth verifying
   against what you actually need it for.
2. **No signature verification on any download.** Chrome, VLC, Drive, Zoom and the Apeos PKG are
   fetched and installed with no `spctl` or `pkgutil --check-signature` check. Installomator
   verifies Team IDs per label and fixes this for the App Store-able ones; the Apeos PKG needs an
   explicit check.
3. **The control plane is a public repo's `main` branch.** `InstallApps.sh` curls an executable
   from `raw.githubusercontent.com` and runs it as root, unverified. Any push to `main` is root
   on the fleet. Fixed in Phase 1 by shipping signed, versioned releases; in the meantime, branch
   protection on `main` is a cheap partial mitigation.
4. **A public repo publishes internal detail** — copier IP addresses and the admin account name.
   Consider making it private, or move the site-specific manifest to a private repo.

---

## 8. Decisions needed from you

1. **Evaluate Mosyle/Jamf School first?** It could remove most of this work. (§2a)
2. **Swift or Go?** Recommending Swift. (§3)
3. **Apple Developer ID available?** Needed to sign and notarize the package. MDM-installed
   packages will run unsigned, but signed is materially better and I'd rather set it up in Phase 1
   than retrofit it.
4. **Reporting destination:** Intune custom attribute only to start, or stand up the Google Sheet
   webhook in Phase 1 too?
5. **Which Finder settings are you happy to *lock*** via profile versus leave user-changeable?
   That decides the §2b split.

# TODO — cleanup from 2026-06-12 troubleshooting session

Context: Dee's MacBook Air (macOS 26.5.1 / Tahoe, arm64) wasn't getting Intune-pushed apps.
Root cause was a cascading deadlock between the Apeos PKG, missing Rosetta 2, and the
InstallApps retry storm. We patched Dee's device but the underlying issues remain.

---

## 1. InstallApps.sh — reorder Rosetta to run first

[scripts/macOS/InstallApps.sh](scripts/macOS/InstallApps.sh)

Rosetta install is currently step 5 (after Chrome 252 MB, VLC, Google Drive). If anything
kills the script during the heavy downloads — for example, the Intune daemon being busy with
another failing PKG policy — Rosetta never installs, which breaks anything that needs it
(e.g. the Apeos PS Plug-in PKG).

**Action:** move the Rosetta block (currently lines ~98–108) to the very top of the script,
before the Chrome download. Cheap, fast, and unblocks everything else.

While we're there, also consider: should the script `exit 1` on the first non-skippable
failure so Intune retries cleanly, rather than logging and continuing? Right now a Chrome
download failure just gets logged and the script proceeds.

---

## 2. Add a dedicated InstallRosetta.sh Intune shell script

Even with reordering, a dedicated script is more robust because:
- It runs independently of InstallApps' other failures
- Intune can retry it on its own schedule
- It's the only thing that gates the Apeos PKG, so it deserves its own policy slot

**Action:** create `scripts/macOS/InstallRosetta.sh` (Apple Silicon check, oahd check,
softwareupdate install, exit on failure), then add as a macOS Shell Script in Intune:
- Run as signed-in user: **No**
- Frequency: every 15 min, 3 retries
- Assign to: macOS Staff group

See [conversation notes — script template was provided].

---

## 3. Apeos PS Plug-in is gated on Rosetta 2

[packages/FUJIFILM PS Plug-in Installer.pkg](packages/FUJIFILM%20PS%20Plug-in%20Installer.pkg)

The PKG contains Intel-only `.plugin` bundles. macOS's `installer` pre-validates and refuses
to install on Apple Silicon devices without Rosetta 2. This is the **actual root cause** of
the whole InstallApps deadlock — once Rosetta isn't there, the PKG fails, Intune retries
forever, the daemon thrashes, sibling scripts get killed.

Rosetta is still supported by Apple through macOS 27 (per Apple support article 102527);
removal is scheduled for macOS 28. So `softwareupdate --install-rosetta --agree-to-license`
should keep working on the OS versions we care about right now. The earlier failure on Dee's
device (returning "Rosetta 2 update is not available") was likely transient — the daemon was
in the middle of a retry storm and softwareupdate's catalog fetch probably timed out.

**Action:** items #1 (reorder Rosetta first in InstallApps.sh) and #2 (dedicated Intune
Rosetta script) are the structural fix — make sure Rosetta is installed before any device is
asked to install the Apeos PKG. Once those are in place, Tahoe devices will work the same as
Sequoia devices.

Longer term, before macOS 28 ships, check FUJIFILM for a Universal-binary update of the PS
Plug-in so the Rosetta dependency goes away.

---

## 4. Intune Photocopier Drivers app — detection rule already fixed, but verify

**Already done** during the session: detection rule changed from the five PDE plug-in bundle
IDs (`com.fujifilm.fb.e15.pde.*`) to the PKG receipt identifier
`com.fujifilm.fb.print.ps.apon.202104.installer` with **Ignore app version: Yes**.

**Action:** confirm post-fix that:
- Devices where the PKG installed pre-fix (Taara's MBP, iMac-Sysadmin) still report
  "Installed" under Apps → Photocopier Drivers → Device install status.
- Dee's MacBook now reports "Installed" (we manually placed the receipt via local install of
  the PKG after installing Rosetta — see Dee's device note below).

If any device flips to "Not installed" after the change, the receipt-based check isn't seeing
something it should, and we'd need a hybrid detection rule.

---

## 5. Dee's MacBook Air — current state and follow-up

We did the following on `dee.teddy@10.46.0.89` during the session:
- Restarted the Intune daemon (`launchctl kickstart -k system/com.microsoft.intuneMDMAgent.daemon`)
- Manually attempted to install the Apeos PKG — **failed** because Rosetta isn't installable
- Company Portal did install during the same window

**Open items for Dee's device:**
- Apeos PKG is **not installed** (Rosetta blocked it). Either install via the manual driver
  source once item #3 is resolved, or accept it as a known unsupported state on this Tahoe device.
- Verify InstallApps.sh now runs cleanly end-to-end (Chrome, VLC, Drive, Zoom, Classview,
  Homebrew). Last check at ~15:32 NZST 12/06 still showed Chrome download getting chopped —
  needs a re-check after the daemon retry storm has fully settled (or after item #1 lands).
- Decide whether to investigate the local `sidecar.sqlite` cache corruption hypothesis or
  just monitor.

---

## 6. Intune installation status alerting

The Apps → Photocopier Drivers → Device install status page showed Dee's device as "Failed"
with `0x87D30143 — The file provided is not supported` since 10/06 22:53. Nobody noticed
until Dee reported the symptom. A simple report subscription or weekly check would have
flagged this much earlier and saved the cascade.

**Action:** consider a Reports → App install status export (weekly) or whatever the
admin-centre equivalent is, sent to the sysadmin mailbox.

---

## 7. Investigate the InstallApps retry storm pattern

When one LOB PKG fails repeatedly (here: Photocopier Drivers), the Intune daemon's
script-orchestration loop runs hot enough to interrupt sibling scripts (like InstallApps)
mid-download. Symptoms seen: 414 InstallApps starts in ~3.5 hours, zero completions, Chrome
download killed at 0–10 % every cycle, daemon log rotating every ~1.5 min at 1 MB.

This means one bad LOB assignment can break the entire macOS Intune script policy stack.
Once the failing app is sorted (item #3), the storm goes away — but the fact that it can
happen at all is worth knowing.

**Action:** no code change, just awareness. If we ever add more LOB PKGs, monitor
`/Library/Logs/Microsoft/Intune/` log rotation rate as a health check.

---

## 8. Minor cleanups noted in passing

- [scripts/macOS/InstallCompanyPortal.sh](scripts/macOS/InstallCompanyPortal.sh) — uncommitted,
  appeared this session. Confirmed working (Company Portal installed on Dee's during sync).
  Either commit it or decide it's no longer needed now that Intune is delivering Company
  Portal directly via PKG policy (we saw it install via the daemon, not the script).
- `InstallApps.sh` is also currently modified (uncommitted) — review the diff before pulling
  in changes from item #1.

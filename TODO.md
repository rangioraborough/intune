# TODO — Apeos / Rosetta / InstallApps remediation (2026-06-12 → 2026-06-15)

Context: Dee's MacBook Air (macOS 26.5.1 / Tahoe, arm64) wasn't getting Intune-pushed apps.
Root cause turned out to be **two** things compounding:
1. Failing PKG **LOB app** policies (Apeos printer driver, gated on Rosetta; and a
   misconfigured Company Portal app) retry every ~10s — a storm.
2. The Intune agent's script-orchestration loop **terminates managed scripts ~every 10s**
   during provisioning, which is shorter than long installs (Rosetta, 250 MB Chrome) take —
   so InstallApps got killed mid-Rosetta every cycle and never finished. `nohup`/`setsid`
   detachment was also killed; only a **LaunchDaemon** survives.

Final architecture (all live as of 2026-06-15, confirmed working on Dee):

- **[InstallApps.sh](scripts/macOS/InstallApps.sh)** is now a thin **launcher** (the script
  assigned in Intune). It fetches the worker from GitHub, writes a one-shot LaunchDaemon, and
  bootstraps it, then exits 0 immediately.
- **[InstallApps-worker.sh](scripts/macOS/InstallApps-worker.sh)** does the real installs as a
  launchd job (owned by PID 1, so the agent can't kill it): Rosetta first → Apeos printer PKG
  (curled from GitHub) → Chrome → VLC → Drive → Zoom → Classview. Removes its plist on finish.
- The **Apeos PKG and Company Portal are no longer Intune LOB apps** — they're installed by
  script ([InstallApps-worker.sh](scripts/macOS/InstallApps-worker.sh) and
  [InstallCompanyPortal.sh](scripts/macOS/InstallCompanyPortal.sh)). This is what removed the
  storm. Shell scripts don't have the aggressive app-retry behaviour.

See memory `intune-agent-kills-long-scripts` for the durable write-up.

---

## ✅ DONE

- **Rosetta first + best-effort error handling** — in the worker; gated on `hw.optional.arm64`,
  verified via `pgrep oahd`.
- **Apeos drivers via script** — worker curls
  [the PKG](packages/FUJIFILM%20PS%20Plug-in%20Installer.pkg) from GitHub raw and installs it
  after Rosetta. Removed from Intune Apps. Confirmed installed on Dee + all 4 copier queues
  came up via [ConfigurePrinters.sh](scripts/macOS/ConfigurePrinters.sh).
- **Company Portal via script** — removed the misconfigured Intune app (detection pointed at
  `com.microsoft.autoupdate2`); [InstallCompanyPortal.sh](scripts/macOS/InstallCompanyPortal.sh)
  shell-script policy is assigned and handles it.
- **Launcher + LaunchDaemon worker** — the fix that lets long installs complete.
- **VLC fix** — switched from the rate-limited GitHub tags API to VideoLAN's `last/macosx/`
  directory. Confirmed installing.
- **Homebrew** — dropped from the worker (itadmin dependency, not needed).
- Dee confirmed: Rosetta, Apeos + queues, Chrome, Drive, Zoom, Classview, VLC all installed
  with no manual intervention and no storm.

---

## ⏳ REMAINING

### A. Paste the final launcher into Intune + reset test
The launchd **launcher** must be the version live in the Intune InstallApps script policy
(replaces all earlier pastes). Worker changes need no re-paste — the launcher pulls from
GitHub each run. Then reset a device and watch it come up clean.

### B. Item #6 — App install-status alerting (still open)
Dee's device sat "Failed" with `0x87D30143` since 10/06 and nobody noticed until the user
reported it. Set up a Reports → App install status export (weekly) to the sysadmin mailbox.
(Lower priority now that the Apeos PKG is no longer an app policy that can fail this way.)

### C. Longer term
Before macOS 28 (Rosetta removal), check FUJIFILM for a Universal-binary PS Plug-in so the
Rosetta dependency goes away. Also revisit whether Company Portal should ever return to an
app policy once its detection is fixed.

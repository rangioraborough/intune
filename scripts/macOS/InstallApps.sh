#!/bin/bash

############################################################################################
##
## InstallApps LAUNCHER — this is the script assigned in Intune.
##
## The Intune agent terminates the scripts it manages roughly every ~10 seconds during
## provisioning, and it also kills detached (nohup/setsid) children — so the long installs
## (Rosetta is minutes, Chrome is ~250 MB) never finish.
##
## To escape the agent entirely, this launcher hands the work to launchd: it fetches the
## worker from GitHub, writes a one-shot LaunchDaemon, and bootstraps it. The worker then
## runs as a launchd job (owned by PID 1, NOT a child of the agent), so the agent cannot
## kill it. The launcher exits 0 immediately.
##
## All install logic lives in InstallApps-worker.sh — edit and push that; no Intune re-paste
## needed (the launcher pulls the latest worker each run). The worker removes the LaunchDaemon
## plist when it finishes, so it is one-shot per trigger.
##
############################################################################################

appname="InstallApps"
logandmetadir="/Library/Logs/Microsoft/IntuneScripts/$appname"
log="$logandmetadir/$appname.log"
worker="$logandmetadir/$appname.worker.sh"
workerurl="https://raw.githubusercontent.com/rangioraborough/intune/main/scripts/macOS/InstallApps-worker.sh"
label="nz.school.rangiora.installapps-worker"
plist="/Library/LaunchDaemons/$label.plist"

[ -d "$logandmetadir" ] || mkdir -p "$logandmetadir"

# A worker is already running — leave it alone and report success.
if /usr/bin/pgrep -fq "$appname.worker.sh"; then
    echo "# $(date) | Worker already running, launcher exiting" >> "$log"
    exit 0
fi

# Fetch the latest worker. If the download fails, exit non-zero so Intune retries next cycle.
if ! /usr/bin/curl -fsSL --connect-timeout 30 --max-time 120 -o "$worker" "$workerurl"; then
    echo "# $(date) | Failed to download worker, will retry next cycle" >> "$log"
    exit 1
fi
/bin/chmod +x "$worker"

# Write the one-shot LaunchDaemon that runs the worker as a launchd job.
/bin/cat > "$plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>nz.school.rangiora.installapps-worker</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Library/Logs/Microsoft/IntuneScripts/InstallApps/InstallApps.worker.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Library/Logs/Microsoft/IntuneScripts/InstallApps/worker.boot.log</string>
    <key>StandardErrorPath</key>
    <string>/Library/Logs/Microsoft/IntuneScripts/InstallApps/worker.boot.log</string>
</dict>
</plist>
PLIST
/usr/sbin/chown root:wheel "$plist"
/bin/chmod 644 "$plist"

# Clear any prior (exited) instance, then start fresh.
/bin/launchctl bootout system/"$label" 2>/dev/null
/bin/launchctl bootstrap system "$plist"
echo "# $(date) | Bootstrapped worker LaunchDaemon ($label)" >> "$log"
exit 0

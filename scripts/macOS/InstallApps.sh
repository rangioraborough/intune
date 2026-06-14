#!/bin/bash

############################################################################################
##
## InstallApps LAUNCHER — this is the script assigned in Intune.
##
## The Intune agent terminates the scripts it manages roughly every ~10 seconds during
## provisioning convergence — far shorter than the installs take (Rosetta is minutes, Chrome
## is ~250 MB). So this launcher does NO slow work: it fetches the worker from GitHub and
## starts it DETACHED in its own session (perl setsid -> reparents to launchd), then exits 0
## immediately. The agent records a fast success and stops killing it; the worker runs the
## real installs uninterrupted.
##
## All install logic lives in InstallApps-worker.sh — edit and push that; no Intune re-paste
## needed (the launcher pulls the latest worker each run).
##
############################################################################################

appname="InstallApps"
logandmetadir="/Library/Logs/Microsoft/IntuneScripts/$appname"
log="$logandmetadir/$appname.log"
worker="$logandmetadir/$appname.worker.sh"
workerurl="https://raw.githubusercontent.com/rangioraborough/intune/main/scripts/macOS/InstallApps-worker.sh"

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

echo "# $(date) | Launching detached worker" >> "$log"
# setsid via perl: new session -> reparents to launchd -> survives the agent's ~10s kill
/usr/bin/nohup /usr/bin/perl -e 'use POSIX qw(setsid); setsid(); exec("/bin/bash", $ARGV[0])' "$worker" >/dev/null 2>&1 &
disown
exit 0

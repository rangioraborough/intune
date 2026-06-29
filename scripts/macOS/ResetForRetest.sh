#!/bin/bash

############################################################################################
##
## TESTING HELPER — NOT for Intune deployment.
##
## Wipes the local run-state that ConfigureDock.sh and ConfigurePrinters.sh use to
## "configure once then hand control to the user", then kicks the Intune agent so it
## re-downloads and re-runs the scripts. Use this on a single test Mac to validate
## changes to those scripts end-to-end.
##
## Why this is needed: both scripts are deliberately idempotent. Once they've run,
## ConfigureDock skips on its version marker + app fingerprint, and ConfigurePrinters
## skips queues that already exist. So simply re-triggering the agent proves nothing -
## you have to clear the local state first.
##
## Run with sudo:   sudo ./ResetForRetest.sh [options]
##
##   --dock-only        Only reset the dock state
##   --printers-only    Only reset the printer state
##   --keep-queues      Reset printer markers but DON'T delete the printer queues
##                      (use to test the idempotency guard / "already present" path)
##   --no-trigger       Reset state but don't kick the agent (do it yourself / reboot)
##   --watch            After triggering, tail the script logs (Ctrl-C to stop)
##
############################################################################################

set -u

if [ "$EUID" -ne 0 ]; then
    echo "Run with sudo: sudo $0 $*" >&2
    exit 1
fi

DO_DOCK=1
DO_PRINTERS=1
KEEP_QUEUES=0
DO_TRIGGER=1
DO_WATCH=0

for arg in "$@"; do
    case "$arg" in
        --dock-only)     DO_PRINTERS=0 ;;
        --printers-only) DO_DOCK=0 ;;
        --keep-queues)   KEEP_QUEUES=1 ;;
        --no-trigger)    DO_TRIGGER=0 ;;
        --watch)         DO_WATCH=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

INTUNE_SCRIPTS="/Library/Logs/Microsoft/IntuneScripts"
QUEUES=(Office_Copier Ruru_Copier Tui_Copier Nga_Rakau_e_Rua_Copier)

echo "==> ResetForRetest starting"

if [ "$DO_DOCK" -eq 1 ]; then
    echo "--> Dock: removing run-state ($INTUNE_SCRIPTS/ConfigureDock)"
    rm -rf "$INTUNE_SCRIPTS/ConfigureDock"
fi

if [ "$DO_PRINTERS" -eq 1 ]; then
    echo "--> Printers: removing run-state ($INTUNE_SCRIPTS/ConfigurePrinters)"
    rm -rf "$INTUNE_SCRIPTS/ConfigurePrinters"

    if [ "$KEEP_QUEUES" -eq 1 ]; then
        echo "--> Printers: keeping existing queues (--keep-queues); will test the"
        echo "    'already present and correct - skipping' guard on re-run"
    else
        for q in "${QUEUES[@]}"; do
            if lpstat -p "$q" &>/dev/null; then
                lpadmin -x "$q" && echo "--> Printers: removed queue $q"
            fi
        done
    fi
fi

if [ "$DO_TRIGGER" -eq 1 ]; then
    if pgrep -x IntuneMdmAgent &>/dev/null; then
        echo "--> Triggering: killing IntuneMdmAgent (launchd will relaunch it and re-check scripts)"
        killall IntuneMdmAgent
    else
        echo "--> IntuneMdmAgent not currently running; it should start on its own schedule."
        echo "    If nothing happens, reboot or open Company Portal > device > Check status."
    fi
    echo "    NOTE: the agent re-runs scripts on its own cadence; allow a few minutes."
else
    echo "--> Skipping agent trigger (--no-trigger). Reboot or 'sudo killall IntuneMdmAgent' when ready."
fi

echo "==> Done."

if [ "$DO_WATCH" -eq 1 ]; then
    LOGS=()
    [ "$DO_DOCK" -eq 1 ]     && LOGS+=("$INTUNE_SCRIPTS/ConfigureDock/ConfigureDock.log")
    [ "$DO_PRINTERS" -eq 1 ] && LOGS+=("$INTUNE_SCRIPTS/ConfigurePrinters/ConfigurePrinters.log")
    echo ""
    echo "==> Watching logs (Ctrl-C to stop). They appear once the agent runs the scripts:"
    printf '    %s\n' "${LOGS[@]}"
    # -F keeps following even though the files don't exist yet / get recreated
    tail -n +1 -F "${LOGS[@]}"
fi

#!/bin/bash

############################################################################################
##
## Manual capture script — NOT for Intune deployment.
##
## Run this on a reference Mac AS THE LOGGED-IN USER (not via sudo) after:
##   1. Installing the Apeos driver pkg
##   2. Adding the three printer queues in System Settings > Printers & Scanners
##   3. Configuring your desired presets via any app's print dialog
##      ("Presets" dropdown > "Save Current Settings as Preset...")
##
## Output is written to ~/Desktop/ApeosPresetCapture/ — send the whole folder back
## so we can bake the presets and queue settings into the Intune install script.
##
############################################################################################

set -e

OUTPUT_DIR="$HOME/Desktop/ApeosPresetCapture"
mkdir -p "$OUTPUT_DIR"

echo "Capturing to $OUTPUT_DIR"
echo

# Flush cfprefsd so the latest preset edits are written to disk before we read them
killall cfprefsd 2>/dev/null || true
sleep 1

## "Any Printer" presets
ANY_DOMAIN="com.apple.print.custompresets"
if defaults read "$ANY_DOMAIN" &>/dev/null; then
    defaults export "$ANY_DOMAIN" "$OUTPUT_DIR/$ANY_DOMAIN.plist"
    echo "  Captured: $ANY_DOMAIN.plist"
else
    echo "  No 'Any Printer' presets found (this is fine if all presets are per-printer)"
fi

## Per-printer presets — one plist per printer queue
shopt -s nullglob
for plist in "$HOME/Library/Preferences/com.apple.print.custompresets.forprinter."*.plist; do
    base=$(basename "$plist" .plist)
    defaults export "$base" "$OUTPUT_DIR/$base.plist" 2>/dev/null
    echo "  Captured: $base.plist"
done
shopt -u nullglob

## CUPS metadata — queue list, available Apeos driver models, current per-queue options
echo
echo "Capturing CUPS info..."
{
    echo "## sw_vers:"
    sw_vers
    echo
    echo "## Installed queues (lpstat -p):"
    lpstat -p 2>/dev/null || echo "(none)"
    echo
    echo "## Default printer (lpstat -d):"
    lpstat -d 2>/dev/null || echo "(none)"
    echo
    echo "## Available driver models matching 'apeos' (lpinfo -m):"
    lpinfo -m 2>/dev/null | grep -i apeos || echo "(no Apeos models found — driver pkg installed?)"
    echo
    echo "## Per-queue full option list (lpoptions -p <queue> -l):"
    for q in $(lpstat -p 2>/dev/null | awk '/^printer/ {print $2}'); do
        echo "--- $q ---"
        echo "Device URI: $(lpstat -v "$q" 2>/dev/null)"
        lpoptions -p "$q" -l 2>/dev/null
        echo
        echo "Current defaults (lpoptions -p <queue>):"
        lpoptions -p "$q" 2>/dev/null
        echo
    done
} > "$OUTPUT_DIR/cups-info.txt"
echo "  Captured: cups-info.txt"

## Convert binary plists to XML so they're human-readable
echo
echo "Converting plists to XML..."
for f in "$OUTPUT_DIR"/*.plist; do
    plutil -convert xml1 "$f"
done

echo
echo "Done. Contents of $OUTPUT_DIR:"
ls -la "$OUTPUT_DIR"
echo
echo "Send the whole ApeosPresetCapture folder back."

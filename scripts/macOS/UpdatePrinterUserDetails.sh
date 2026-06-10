#!/bin/bash

############################################################################################
##
## Update Apeos printer presets with the teacher's name and accounting code.
##
## Run AS THE LOGGED-IN USER (not via sudo).
##
## Usage:
##   ./UpdatePrinterUserDetails.sh --name <teacher name> --code <accounting code>
##
##   --name   The name that appears on the printer's secure-print release screen
##            (the "User ID" field in the Apeos Secure Print Setup dialog).
##   --code   The numeric accounting/quota code (the "User ID" field in the
##            Apeos User Details Setup / Job-Based Accounting dialog).
##
## Either flag is optional — only what you pass gets updated. Run with no args
## for an interactive prompt.
##
## Passcodes are stored encrypted by the driver and are NOT touched here;
## set those once via the print dialog after running this script.
##
############################################################################################

set -e

PLIST="$HOME/Library/Preferences/com.apple.print.custompresets.plist"
PER_PRINTER_GLOB="$HOME/Library/Preferences/com.apple.print.custompresets.forprinter."*.plist

if [ "$EUID" -eq 0 ]; then
    echo "Run this as the logged-in user, not with sudo." >&2
    exit 1
fi

# GUI mode: no controlling tty (e.g. launched by double-clicking a .app)
GUI_MODE=0
if [ ! -t 0 ] && [ ! -t 1 ]; then
    GUI_MODE=1
fi

gui_prompt() {
    osascript <<APPLESCRIPT 2>/dev/null
try
    set theResult to text returned of (display dialog "$1" default answer "" with title "Update Printer Details" with icon note)
    return theResult
on error number -128
    return ""
end try
APPLESCRIPT
}

gui_info() {
    osascript -e "display dialog \"$1\" buttons {\"OK\"} default button \"OK\" with title \"Update Printer Details\" with icon note" &>/dev/null
}

gui_error() {
    osascript -e "display dialog \"$1\" buttons {\"OK\"} default button \"OK\" with title \"Update Printer Details\" with icon stop" &>/dev/null
}

fail() {
    if [ "$GUI_MODE" -eq 1 ]; then
        gui_error "$1"
    else
        echo "$1" >&2
    fi
    exit 1
}

if [ ! -f "$PLIST" ]; then
    fail "No printer presets found yet. Make sure the Apeos printers are installed before running this."
fi

TEACHER_NAME=""
ACCOUNT_CODE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --name) TEACHER_NAME="$2"; shift 2 ;;
        --code) ACCOUNT_CODE="$2"; shift 2 ;;
        -h|--help)
            grep -E '^## ' "$0" | sed 's/^## \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$TEACHER_NAME" ] && [ -z "$ACCOUNT_CODE" ]; then
    if [ "$GUI_MODE" -eq 1 ]; then
        TEACHER_NAME=$(gui_prompt "Enter your teacher name (as it should appear on the printer's secure-print release screen):")
        ACCOUNT_CODE=$(gui_prompt "Enter your accounting code:")
    else
        read -r -p "Teacher name (leave blank to skip): " TEACHER_NAME
        read -r -p "Accounting code (leave blank to skip): " ACCOUNT_CODE
    fi
fi

if [ -z "$TEACHER_NAME" ] && [ -z "$ACCOUNT_CODE" ]; then
    if [ "$GUI_MODE" -eq 1 ]; then
        gui_info "No values entered — nothing to update."
    else
        echo "Nothing to update."
    fi
    exit 0
fi

# Flush cfprefsd so we read/write the live state, not a stale cache
killall cfprefsd 2>/dev/null || true
sleep 1

# List top-level preset names. PlistBuddy is fine for the top level (no traversal
# into keys-with-spaces), and avoids needing python/jq.
PRESETS=$(/usr/libexec/PlistBuddy -c "Print" "$PLIST" \
    | awk -F' = ' '/^    [^ ].* = Dict \{/ {sub(/^    /,""); sub(/ = Dict \{$/,""); print}')

if [ -z "$PRESETS" ]; then
    echo "No presets found in $PLIST" >&2
    exit 1
fi

# plutil path format: dots separate path components; literal dots in key names
# are escaped with backslash. Spaces in key names are passed through as-is.
DOTTED_SETTINGS='com\.apple\.print\.preset\.settings'
KEY_PREFIX='com\.fujifilm\.fb\.jt\.printsettings\.ps\.ap'

# Set a single fujifilm key inside an arbitrary base path of an arbitrary plist
set_key_at() {
    local file="$1" base_path="$2" key="$3" value="$4"
    local path="${base_path}.${KEY_PREFIX}\.${key}"
    if plutil -extract "$path" raw "$file" &>/dev/null; then
        plutil -replace "$path" -string "$value" "$file"
        return 0
    fi
    return 1
}

# Apply both name + code keys at a given base path in a given file, with logging
apply_at() {
    local file="$1" base_path="$2"
    local set_any
    if [ -n "$TEACHER_NAME" ]; then
        set_any=0
        for KEY in PrintTypeUserNameReference PrintTypeUserNameTicketKey; do
            if set_key_at "$file" "$base_path" "$KEY" "$TEACHER_NAME"; then
                set_any=1
            fi
        done
        if [ "$set_any" -eq 1 ]; then
            echo "  name = $TEACHER_NAME"
        fi
    fi
    if [ -n "$ACCOUNT_CODE" ]; then
        set_any=0
        for KEY in JBAUserIDTextEditReference JBAUserIDTextEditTicket; do
            if set_key_at "$file" "$base_path" "$KEY" "$ACCOUNT_CODE"; then
                set_any=1
            fi
        done
        if [ "$set_any" -eq 1 ]; then
            echo "  code = $ACCOUNT_CODE"
        fi
    fi
}

# 1. Named presets in the cross-printer plist
while IFS= read -r PRESET; do
    [ -z "$PRESET" ] && continue
    echo "Preset: $PRESET"
    apply_at "$PLIST" "${PRESET}.${DOTTED_SETTINGS}"
done <<< "$PRESETS"

# 2. Per-printer plists — these store the live "last used" values that the
#    print dialog displays, under com.apple.print.v2.lastUsedSettingsPref
shopt -s nullglob
LAST_USED_PATH='com\.apple\.print\.v2\.lastUsedSettingsPref'
for pp_plist in $PER_PRINTER_GLOB; do
    # Skip if no lastUsedSettingsPref dict exists
    plutil -extract "$LAST_USED_PATH" raw "$pp_plist" &>/dev/null || continue
    printer_name=$(basename "$pp_plist" .plist | sed 's/^com.apple.print.custompresets.forprinter.//')
    echo "Printer: $printer_name (live values)"
    apply_at "$pp_plist" "$LAST_USED_PATH"
done
shopt -u nullglob

# Flush again so apps pick up the new values immediately
killall cfprefsd 2>/dev/null || true

if [ "$GUI_MODE" -eq 1 ]; then
    gui_info "Done. Please restart your Mac for the changes to take effect.\n\nNote: passcodes are encrypted by the printer driver and were not changed — set those once via any app's print dialog if they need updating."
else
    echo
    echo "Done. A reboot is required for the dialog to show the new values."
    echo "Note: passcodes are encrypted by the printer driver and were not changed —"
    echo "set those via the print dialog if they need updating."
fi

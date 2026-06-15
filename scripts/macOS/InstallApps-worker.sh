#!/bin/bash

############################################################################################
##
## InstallApps WORKER — does the actual installs (Rosetta, FUJIFILM Apeos printer drivers,
## Google Chrome, VLC, Google Drive, Zoom, Classview, Homebrew).
##
## This is NOT assigned in Intune directly. It is fetched from GitHub and launched DETACHED
## by InstallApps.sh (the launcher). It runs in its own session, reparented to launchd, so
## the Intune agent's ~10s script-orchestration kill cannot interrupt the long installs.
##
## To change what gets installed, edit THIS file and push to GitHub — the launcher pulls the
## latest copy each run, so no Intune re-paste is needed.
##
############################################################################################

appname="InstallApps"
logandmetadir="/Library/Logs/Microsoft/IntuneScripts/$appname"
log="$logandmetadir/$appname.log"
lock="$logandmetadir/$appname.lock"

[ -d "$logandmetadir" ] || mkdir -p "$logandmetadir"

echo $$ > "$lock"
trap 'rm -f "$lock"' EXIT

exec &> >(tee -a "$log")

echo ""
echo "##############################################################"
echo "# $(date) | Starting $appname worker (PID $$)"
echo "##############################################################"
echo ""

errors=0

## Install Rosetta (FIRST — the Apeos PS Plug-in PKG is Intel-only and will not install
## without it)
if [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then
    if /usr/bin/pgrep -q oahd; then
        echo " $(date) | Rosetta already installed, skipping"
    else
        echo " $(date) | Installing Rosetta"
        softwareupdate --install-rosetta --agree-to-license
        # Verify by checking the daemon — softwareupdate can return 0 without installing
        if /usr/bin/pgrep -q oahd; then
            echo " $(date) | Rosetta installed successfully"
        else
            echo " $(date) | Failed to install Rosetta"
            errors=$((errors+1))
        fi
    fi
else
    echo " $(date) | Not Apple Silicon, Rosetta not required"
fi

## Install Photocopier drivers (FUJIFILM Apeos PS Plug-in)
## Installed here rather than as an Intune LOB app so it runs strictly AFTER Rosetta in the
## same worker. The PKG is Intel-only and fails without Rosetta; as a separate app policy
## that failure caused the Intune retry storm. Gated on Rosetta being present.
if pkgutil --pkg-info com.fujifilm.fb.print.ps.apon.202104.installer &>/dev/null; then
    echo " $(date) | Photocopier drivers already installed, skipping"
elif /usr/bin/pgrep -q oahd; then
    echo " $(date) | Downloading Photocopier drivers"
    curl -L --connect-timeout 30 --max-time 300 -o /tmp/apeos-drivers.pkg "https://raw.githubusercontent.com/rangioraborough/intune/main/packages/FUJIFILM%20PS%20Plug-in%20Installer.pkg"
    if [ "$?" = "0" ]; then
        echo " $(date) | Installing Photocopier drivers"
        installer -pkg /tmp/apeos-drivers.pkg -target /
        if [ "$?" = "0" ]; then
            rm /tmp/apeos-drivers.pkg
            echo " $(date) | Photocopier drivers installed successfully"
        else
            echo " $(date) | Failed to install Photocopier drivers"
            errors=$((errors+1))
        fi
    else
        echo " $(date) | Failed to download Photocopier drivers"
        errors=$((errors+1))
    fi
else
    echo " $(date) | Rosetta not present yet, skipping Photocopier drivers this run"
fi

## Install Google Chrome
if [ ! -d "/Applications/Google Chrome.app" ]; then
    echo " $(date) | Downloading Google Chrome"
    curl -L --connect-timeout 30 --max-time 300 -o /tmp/googlechrome.dmg "https://dl.google.com/chrome/mac/universal/stable/googlechrome.dmg"
    if [ "$?" = "0" ]; then
        echo " $(date) | Mounting Chrome DMG"
        hdiutil attach /tmp/googlechrome.dmg -nobrowse -quiet
        sleep 3
        echo " $(date) | Installing Chrome"
        cp -R "/Volumes/Google Chrome/Google Chrome.app" /Applications/
        hdiutil detach "/Volumes/Google Chrome" -quiet
        rm /tmp/googlechrome.dmg
        echo " $(date) | Google Chrome installed successfully"
    else
        echo " $(date) | Failed to download Google Chrome"
        errors=$((errors+1))
    fi
else
    echo " $(date) | Google Chrome already installed, skipping"
fi

## Install VLC
if [ ! -d "/Applications/VLC.app" ]; then
    echo " $(date) | Finding latest VLC (arm64)"
    # Use VideoLAN's own 'last' directory — the GitHub API tag scrape was unreliable
    # (rate-limited from the device, returned an empty version -> broken download URL).
    VLC_DMG=$(curl -s --connect-timeout 30 "https://get.videolan.org/vlc/last/macosx/" | grep -oE 'vlc-[0-9.]+-arm64\.dmg' | head -1)
    echo " $(date) | Latest VLC dmg: ${VLC_DMG:-<none found>}"
    echo " $(date) | Downloading VLC"
    curl -L --connect-timeout 30 --max-time 300 -o /tmp/vlc.dmg "https://get.videolan.org/vlc/last/macosx/${VLC_DMG}"
    if [ "$?" = "0" ]; then
        echo " $(date) | Mounting VLC DMG"
        hdiutil attach /tmp/vlc.dmg -nobrowse
        sleep 5
        VLC_VOLUME="/Volumes/VLC media player"
        echo " $(date) | VLC volume set to $VLC_VOLUME"
        if [ -d "$VLC_VOLUME" ]; then
            cp -R "$VLC_VOLUME/VLC.app" /Applications/
            hdiutil detach "$VLC_VOLUME" -quiet
            rm /tmp/vlc.dmg
            echo " $(date) | VLC installed successfully"
        else
            echo " $(date) | Failed to find VLC volume at $VLC_VOLUME"
            errors=$((errors+1))
        fi
    else
        echo " $(date) | Failed to download VLC"
        errors=$((errors+1))
    fi
else
    echo " $(date) | VLC already installed, skipping"
fi

## Install Google Drive
if [ ! -d "/Applications/Google Drive.app" ]; then
    echo " $(date) | Downloading Google Drive"
    curl -L --connect-timeout 30 --max-time 300 -o /tmp/googledrive.dmg "https://dl.google.com/drive-file-stream/GoogleDrive.dmg"
    if [ "$?" = "0" ]; then
        echo " $(date) | Mounting Google Drive DMG"
        hdiutil attach /tmp/googledrive.dmg -nobrowse -quiet
        sleep 3
        echo " $(date) | Installing Google Drive"
        installer -pkg "/Volumes/Install Google Drive/GoogleDrive.pkg" -target /
        hdiutil detach "/Volumes/Install Google Drive" -quiet
        rm /tmp/googledrive.dmg
        echo " $(date) | Google Drive installed successfully"
    else
        echo " $(date) | Failed to download Google Drive"
        errors=$((errors+1))
    fi
else
    echo " $(date) | Google Drive already installed, skipping"
fi

## Install Zoom
if [ ! -d "/Applications/zoom.us.app" ]; then
    echo " $(date) | Downloading Zoom"
    curl -L --connect-timeout 30 --max-time 300 -o /tmp/zoom.pkg "https://zoom.us/client/latest/ZoomInstallerIT.pkg"
    if [ "$?" = "0" ]; then
        echo " $(date) | Installing Zoom"
        installer -pkg /tmp/zoom.pkg -target /
        rm /tmp/zoom.pkg
        echo " $(date) | Zoom installed successfully"
    else
        echo " $(date) | Failed to download Zoom"
        errors=$((errors+1))
    fi
else
    echo " $(date) | Zoom already installed, skipping"
fi

## Create / repair Classview app (Chrome web shortcut + bundled icon)
## Icon is a prebuilt .icns in the repo (the site's favicon is an SVG that sips can't
## rasterise). Fetched from GitHub, same as the Apeos PKG.
CLASSVIEW_APP="/Applications/Classview.app"
CLASSVIEW_ICNS_URL="https://raw.githubusercontent.com/rangioraborough/intune/main/assets/macOS/classview/Classview.icns"

if [ ! -d "$CLASSVIEW_APP" ]; then
    echo " $(date) | Creating Classview app"
    mkdir -p "$CLASSVIEW_APP/Contents/MacOS"
    mkdir -p "$CLASSVIEW_APP/Contents/Resources"

    # Create the launcher script
    cat > "$CLASSVIEW_APP/Contents/MacOS/Classview" << 'EOF'
#!/bin/bash
open -a "Google Chrome" "https://rangiora.classview.co.nz"
EOF
    chmod +x "$CLASSVIEW_APP/Contents/MacOS/Classview"

    # Create Info.plist
    cat > "$CLASSVIEW_APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Classview</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>nz.co.classview.rangiora</string>
    <key>CFBundleName</key>
    <string>Classview</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
</dict>
</plist>
EOF
    echo " $(date) | Classview app created"
else
    echo " $(date) | Classview app already present"
fi

# Install the bundled icon if missing (also repairs devices created before this fix)
if [ -d "$CLASSVIEW_APP" ] && [ ! -f "$CLASSVIEW_APP/Contents/Resources/AppIcon.icns" ]; then
    echo " $(date) | Fetching Classview icon"
    if curl -fsSL --connect-timeout 30 --max-time 60 -o "$CLASSVIEW_APP/Contents/Resources/AppIcon.icns" "$CLASSVIEW_ICNS_URL"; then
        touch "$CLASSVIEW_APP"
        /usr/bin/killall Dock 2>/dev/null
        echo " $(date) | Classview icon installed"
    else
        echo " $(date) | Failed to fetch Classview icon, using generic icon"
        errors=$((errors+1))
    fi
fi

rm -f "$lock"

# Remove the one-shot LaunchDaemon plist so we don't re-run at every boot. Removing the file
# does NOT kill this running job; the launcher re-creates + bootstraps it next time if needed.
rm -f "/Library/LaunchDaemons/nz.school.rangiora.installapps-worker.plist"

if [ "$errors" -gt 0 ]; then
    echo " $(date) | App installation worker complete with $errors failed step(s)"
    exit 1
else
    echo " $(date) | App installation worker complete"
    exit 0
fi

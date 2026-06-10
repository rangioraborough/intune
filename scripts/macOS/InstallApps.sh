#!/bin/bash

############################################################################################
##
## Script to install Google Chrome, VLC, Google Drive and Zoom
##
############################################################################################

appname="InstallApps"
logandmetadir="/Library/Logs/Microsoft/IntuneScripts/$appname"
log="$logandmetadir/$appname.log"

if [ -d $logandmetadir ]; then
    echo "# $(date) | Log directory already exists - $logandmetadir"
else
    echo "# $(date) | Creating log directory - $logandmetadir"
    mkdir -p $logandmetadir
fi

exec &> >(tee -a "$log")

echo ""
echo "##############################################################"
echo "# $(date) | Starting $appname"
echo "##############################################################"
echo ""

## Install Google Chrome
if [ ! -d "/Applications/Google Chrome.app" ]; then
    echo " $(date) | Downloading Google Chrome"
    curl -L -o /tmp/googlechrome.dmg "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg"
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
    fi
else
    echo " $(date) | Google Chrome already installed, skipping"
fi

## Install VLC
if [ ! -d "/Applications/VLC.app" ]; then
    echo " $(date) | Getting latest VLC version"
    VLC_VERSION=$(curl -s "https://api.github.com/repos/videolan/vlc/tags" | grep -o '"name": "[0-9.]*"' | head -1 | grep -o '[0-9.]*')
    echo " $(date) | Latest VLC version: $VLC_VERSION"
    echo " $(date) | Downloading VLC"
    curl -L -o /tmp/vlc.dmg "https://get.videolan.org/vlc/$VLC_VERSION/macosx/vlc-$VLC_VERSION-arm64.dmg"
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
            exit 1
        fi
    else
        echo " $(date) | Failed to download VLC"
    fi
else
    echo " $(date) | VLC already installed, skipping"
fi

## Install Google Drive
if [ ! -d "/Applications/Google Drive.app" ]; then
    echo " $(date) | Downloading Google Drive"
    curl -L -o /tmp/googledrive.dmg "https://dl.google.com/drive-file-stream/GoogleDrive.dmg"
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
    fi
else
    echo " $(date) | Google Drive already installed, skipping"
fi

## Install Rosetta
if /usr/bin/pgrep -q oahd; then
    echo " $(date) | Rosetta already installed, skipping"
else
    echo " $(date) | Installing Rosetta"
    softwareupdate --install-rosetta --agree-to-license
    if [ "$?" = "0" ]; then
        echo " $(date) | Rosetta installed successfully"
    else
        echo " $(date) | Failed to install Rosetta"
    fi
fi

## Install Zoom
if [ ! -d "/Applications/zoom.us.app" ]; then
    echo " $(date) | Downloading Zoom"
    curl -L -o /tmp/zoom.pkg "https://zoom.us/client/latest/ZoomInstallerIT.pkg"
    if [ "$?" = "0" ]; then
        echo " $(date) | Installing Zoom"
        installer -pkg /tmp/zoom.pkg -target /
        rm /tmp/zoom.pkg
        echo " $(date) | Zoom installed successfully"
    else
        echo " $(date) | Failed to download Zoom"
    fi
else
    echo " $(date) | Zoom already installed, skipping"
fi

## Create Classview app
if [ ! -d "/Applications/Classview.app" ]; then
    echo " $(date) | Creating Classview app"
    mkdir -p "/Applications/Classview.app/Contents/MacOS"
    mkdir -p "/Applications/Classview.app/Contents/Resources"

    # Create the launcher script — Chrome --app mode gives a chromeless standalone window
    cat > "/Applications/Classview.app/Contents/MacOS/Classview" << 'EOF'
#!/bin/bash
exec "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --app="https://rangiora.classview.co.nz"
EOF
    chmod +x "/Applications/Classview.app/Contents/MacOS/Classview"

    # Download favicon and convert to icns
    echo " $(date) | Downloading Classview favicon"
    ICON_DOWNLOADED=false
    rm -f /tmp/classview_favicon.png /tmp/classview_favicon.svg /tmp/classview_favicon.svg.png
    for FAVICON_URL in \
        "https://rangiora.classview.co.nz/favicon.svg" \
        "https://rangiora.classview.co.nz/favicon.png" \
        "https://rangiora.classview.co.nz/apple-touch-icon.png" \
        "https://rangiora.classview.co.nz/apple-touch-icon-precomposed.png"; do
        echo " $(date) | Trying $FAVICON_URL"
        if [[ "$FAVICON_URL" == *.svg ]]; then
            curl -L --silent --fail -o /tmp/classview_favicon.svg "$FAVICON_URL"
            if [ "$?" = "0" ]; then
                echo " $(date) | Rasterising SVG to PNG with qlmanage"
                qlmanage -t -s 1024 -o /tmp /tmp/classview_favicon.svg &>/dev/null
                if [ -f "/tmp/classview_favicon.svg.png" ]; then
                    mv /tmp/classview_favicon.svg.png /tmp/classview_favicon.png
                fi
                rm -f /tmp/classview_favicon.svg
            fi
        else
            curl -L --silent --fail -o /tmp/classview_favicon.png "$FAVICON_URL"
        fi
        if [ -f /tmp/classview_favicon.png ] && sips -g pixelWidth /tmp/classview_favicon.png &>/dev/null; then
            echo " $(date) | Successfully downloaded icon from $FAVICON_URL"
            ICON_DOWNLOADED=true
            break
        fi
        rm -f /tmp/classview_favicon.png
    done

    if [ "$ICON_DOWNLOADED" = "true" ]; then
        mkdir -p /tmp/classview.iconset
        sips -z 16 16     /tmp/classview_favicon.png --out /tmp/classview.iconset/icon_16x16.png
        sips -z 32 32     /tmp/classview_favicon.png --out /tmp/classview.iconset/icon_16x16@2x.png
        sips -z 32 32     /tmp/classview_favicon.png --out /tmp/classview.iconset/icon_32x32.png
        sips -z 64 64     /tmp/classview_favicon.png --out /tmp/classview.iconset/icon_32x32@2x.png
        sips -z 128 128   /tmp/classview_favicon.png --out /tmp/classview.iconset/icon_128x128.png
        sips -z 256 256   /tmp/classview_favicon.png --out /tmp/classview.iconset/icon_128x128@2x.png
        sips -z 256 256   /tmp/classview_favicon.png --out /tmp/classview.iconset/icon_256x256.png
        sips -z 512 512   /tmp/classview_favicon.png --out /tmp/classview.iconset/icon_256x256@2x.png
        sips -z 512 512   /tmp/classview_favicon.png --out /tmp/classview.iconset/icon_512x512.png
        iconutil -c icns /tmp/classview.iconset -o "/Applications/Classview.app/Contents/Resources/AppIcon.icns"
        rm -rf /tmp/classview.iconset /tmp/classview_favicon.png
        echo " $(date) | Classview icon set successfully"
    else
        echo " $(date) | Could not download a valid favicon, app will use generic icon"
    fi

    # Create Info.plist
    cat > "/Applications/Classview.app/Contents/Info.plist" << 'EOF'
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
    echo " $(date) | Classview app created successfully"
else
    echo " $(date) | Classview already installed, skipping"
fi

echo " $(date) | App installation script complete"
exit 0
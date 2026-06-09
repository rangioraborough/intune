#!/bin/bash

############################################################################################
##
## Script to install Google Chrome, VLC and Google Drive
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

echo " $(date) | App installation script complete"
exit 0
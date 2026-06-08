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
    echo " $(date) | Downloading VLC"
    curl -L -o /tmp/vlc.dmg "https://get.videolan.org/vlc/last/macosx/vlc-arm64.dmg"
    if [ "$?" = "0" ]; then
        echo " $(date) | Mounting VLC DMG"
        hdiutil attach /tmp/vlc.dmg -nobrowse -quiet
        ## Find the mounted VLC volume dynamically
        VLC_VOLUME=$(hdiutil info | grep -i vlc | grep "Apple_HFS" | awk '{print $NF}')
        echo " $(date) | VLC volume detected as $VLC_VOLUME"
        if [ -n "$VLC_VOLUME" ]; then
            cp -R "$VLC_VOLUME/VLC.app" /Applications/
            hdiutil detach "$VLC_VOLUME" -quiet
            rm /tmp/vlc.dmg
            echo " $(date) | VLC installed successfully"
        else
            echo " $(date) | Failed to detect VLC volume"
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
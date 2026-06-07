#!/bin/bash

############################################################################################
##
## Script to set desktop wallpaper
##
############################################################################################

appname="SetWallpaper"
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

## Download wallpaper
WallpaperDir="/Library/RBS/Wallpaper"
mkdir -p "$WallpaperDir"
WallpaperPath="$WallpaperDir/RBS-Background.jpg"

curl -L -o "$WallpaperPath" "https://raw.githubusercontent.com/rangioraborough/intune/main/assets/macOS/backgrounds/RBS-Background_3888x2592.jpg"
if [ "$?" = "0" ]; then
    echo " $(date) | Wallpaper downloaded to $WallpaperPath"
else
    echo " $(date) | Failed to download wallpaper"
    exit 1
fi

## Set wallpaper for logged in user
LoggedInUser=$(stat -f "%Su" /dev/console)
if [[ -z "$LoggedInUser" || "$LoggedInUser" == "root" ]]; then
    echo " $(date) | No user logged in, exiting"
    exit 1
fi

sudo -u "$LoggedInUser" osascript -e "tell application \"Finder\" to set desktop picture to POSIX file \"$WallpaperPath\""
if [ "$?" = "0" ]; then
    echo " $(date) | Wallpaper set successfully for $LoggedInUser"
else
    echo " $(date) | Failed to set wallpaper"
    exit 1
fi

echo " $(date) | Wallpaper script complete"
exit 0
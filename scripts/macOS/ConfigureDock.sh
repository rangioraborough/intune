#!/bin/bash

############################################################################################
##
## Script to configure macOS Dock
##
############################################################################################

appname="ConfigureDock"
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

## Get logged in user
LoggedInUser=$(stat -f "%Su" /dev/console)
if [[ -z "$LoggedInUser" || "$LoggedInUser" == "root" ]]; then
    echo " $(date) | No user logged in, exiting"
    exit 1
fi
echo " $(date) | Logged in user detected as $LoggedInUser"

## Define dock apps - modify this list as needed
declare -a DockApps=(
    "/Applications/Google Chrome.app"
    "/Applications/Google Drive.app"
    "/System/Applications/Calendar.app"
    "/Applications/Classview.app"
    "/System/Applications/Mail.app"
    "/Applications/Company Portal.app"
    "/Applications/Microsoft Word.app"
    "/Applications/Microsoft Excel.app"
    "/Applications/Microsoft PowerPoint.app"
    "/Applications/Classroom.app"
    "/System/Applications/System Settings.app"
)

## Clear existing dock apps
sudo -u "$LoggedInUser" defaults write com.apple.dock persistent-apps -array
echo " $(date) | Cleared existing dock apps"

## Add apps to dock
for app in "${DockApps[@]}"; do
    if [ -e "$app" ]; then
        sudo -u "$LoggedInUser" defaults write com.apple.dock persistent-apps -array-add \
            "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$app</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
        echo " $(date) | Added $app to dock"
    else
        echo " $(date) | $app not found, skipping"
    fi
done

## Disable recent apps in dock
sudo -u "$LoggedInUser" defaults write com.apple.dock show-recents -bool false
echo " $(date) | Disabled recent apps in dock"

## Restart dock to apply changes
sudo -u "$LoggedInUser" killall Dock
echo " $(date) | Dock restarted"

echo " $(date) | Dock configuration complete"
exit 0
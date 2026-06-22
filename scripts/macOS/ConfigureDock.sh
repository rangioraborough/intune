#!/bin/bash

############################################################################################
##
## Script to configure macOS Dock
##
############################################################################################

appname="ConfigureDock"
logandmetadir="/Library/Logs/Microsoft/IntuneScripts/$appname"
log="$logandmetadir/$appname.log"

## Bump this whenever the DockApps list changes to force a one-time re-apply.
## The version is baked into the marker filename, so a new version won't match
## the old marker and the dock gets rebuilt once before being handed back to the user.
dockversion="1"
marker="$logandmetadir/$appname.v$dockversion.done"

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

## If we've already configured the dock once (with all apps present), leave it alone
## so the user's own dock customisations are preserved on subsequent runs.
if [ -f "$marker" ]; then
    echo " $(date) | Dock already configured ($marker present) - leaving user's dock untouched"
    exit 0
fi

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
## Track whether every app was present so we only mark "done" once the dock is
## fully built - apps deployed by Intune may not be installed yet on early runs.
missing=0
for app in "${DockApps[@]}"; do
    if [ -e "$app" ]; then
        sudo -u "$LoggedInUser" defaults write com.apple.dock persistent-apps -array-add \
            "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$app</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
        echo " $(date) | Added $app to dock"
    else
        missing=$((missing + 1))
        echo " $(date) | $app not found, skipping"
    fi
done

## Disable recent apps in dock
sudo -u "$LoggedInUser" defaults write com.apple.dock show-recents -bool false
echo " $(date) | Disabled recent apps in dock"

## Restart dock to apply changes
sudo -u "$LoggedInUser" killall Dock
echo " $(date) | Dock restarted"

## Only mark as done once every app was present, so later runs can still add
## apps that hadn't finished installing yet. Once done, the dock is handed over
## to the user and won't be reconfigured again.
if [ "$missing" -eq 0 ]; then
    ## Remove any older-version markers so they don't accumulate
    rm -f "$logandmetadir/$appname".v*.done
    touch "$marker"
    echo " $(date) | All apps present - marking dock configuration complete ($marker)"
else
    echo " $(date) | $missing app(s) not yet installed - will reconfigure on next run"
fi

echo " $(date) | Dock configuration complete"
exit 0
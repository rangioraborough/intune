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
## The version is baked into the marker filenames, so a new version won't match
## the old marker and the dock gets rebuilt once before being handed back to the user.
dockversion="2"
marker="$logandmetadir/$appname.v$dockversion.done"
## Fingerprint of which listed apps were installed last time we (re)built the dock.
## We only rebuild when this set changes (i.e. a new app from the list appeared),
## then hand the dock back to the user. This means a single app that never installs
## no longer blocks completion - the old "all apps present" gate reset the dock on
## EVERY run whenever any app was missing, wiping the user's customisations.
sigfile="$logandmetadir/$appname.v$dockversion.sig"

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

## Fingerprint the set of listed apps currently installed. We only (re)build the
## dock when this set changes from the last build - i.e. when a new app from the
## list has finished installing. Once it stabilises the dock is handed to the user
## and left alone, so an app that never installs no longer forces a reset each run.
currentsig=""
for app in "${DockApps[@]}"; do
    [ -e "$app" ] && currentsig="${currentsig}${app}"$'\n'
done

if [ -f "$marker" ] && [ -f "$sigfile" ] && [ "$(cat "$sigfile")" = "$(printf '%s' "$currentsig")" ]; then
    echo " $(date) | Dock already configured and no new apps installed since - leaving user's dock untouched"
    exit 0
fi

## Clear existing dock apps
sudo -u "$LoggedInUser" defaults write com.apple.dock persistent-apps -array
echo " $(date) | Cleared existing dock apps"

## Add apps to dock
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

## Record the set of apps we just built the dock from. On the next run, if no new
## listed app has appeared, the fingerprint matches and we leave the dock alone -
## handing it to the user. If another app finishes installing later, the fingerprint
## changes and we rebuild once more to include it. Either way, a perpetually-missing
## app no longer triggers a reset on every run.
rm -f "$logandmetadir/$appname".v*.done "$logandmetadir/$appname".v*.sig 2>/dev/null
printf '%s' "$currentsig" > "$sigfile"
touch "$marker"
if [ "$missing" -eq 0 ]; then
    echo " $(date) | All apps present - dock built and handed to user"
else
    echo " $(date) | $missing app(s) not yet installed - dock built with what's present; will rebuild only if one appears later"
fi

echo " $(date) | Dock configuration complete"
exit 0
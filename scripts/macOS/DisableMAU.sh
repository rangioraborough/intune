#!/bin/bash

############################################################################################
##
## Script to disable Microsoft AutoUpdate
##
############################################################################################

appname="DisableMAU"
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

## Disable MAU via defaults
defaults write /Library/Preferences/com.microsoft.autoupdate2 EnableAutoUpdate -bool false
defaults write /Library/Preferences/com.microsoft.autoupdate2 EnableCheckForUpdates -bool false
defaults write /Library/Preferences/com.microsoft.autoupdate2 StartDaemonOnAppLaunch -bool false
echo " $(date) | MAU defaults written"

## Unload MAU launch agent
if [ -f /Library/LaunchAgents/com.microsoft.update.agent.plist ]; then
    launchctl unload -w /Library/LaunchAgents/com.microsoft.update.agent.plist 2>/dev/null
    echo " $(date) | MAU launch agent unloaded"
else
    echo " $(date) | MAU launch agent not found, skipping"
fi

echo " $(date) | DisableMAU script complete"
exit 0
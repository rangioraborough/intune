#!/bin/bash

############################################################################################
##
## Script to set Google Chrome as the default browser
##
############################################################################################

appname="SetDefaultBrowser"
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

## Set Chrome as default browser
CURRENT_USER=$(stat -f "%Su" /dev/console)
echo " $(date) | Setting Chrome as default browser for $CURRENT_USER"

sudo -u "$CURRENT_USER" /usr/bin/defaults write com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers -array-add \
    '{LSHandlerContentType = "public.html"; LSHandlerRoleAll = "com.google.chrome";
      LSHandlerURLScheme = "http"; LSHandlerRoleAll = "com.google.chrome";
      LSHandlerURLScheme = "https"; LSHandlerRoleAll = "com.google.chrome";}'

if [ "$?" = "0" ]; then
    echo " $(date) | Chrome set as default browser successfully"
else
    echo " $(date) | Failed to set Chrome as default browser, trying alternative method"

    # Alternative method using bundleid
    sudo -u "$CURRENT_USER" /usr/bin/open -a "Google Chrome" --args --make-default-browser
fi

echo " $(date) | SetDefaultBrowser script complete"
exit 0
#!/bin/bash

############################################################################################
##
## Script to rename a Mac based on device type and logged-in username
##
############################################################################################

## Define variables
appname="DeviceRename"
logandmetadir="/Library/Logs/Microsoft/IntuneScripts/$appname"
log="$logandmetadir/$appname.log"

## Check if the log directory has been created
if [ -d $logandmetadir ]; then
    echo "# $(date) | Log directory already exists - $logandmetadir"
else
    echo "# $(date) | Creating log directory - $logandmetadir"
    mkdir -p $logandmetadir
fi

# Start logging
exec &> >(tee -a "$log")

echo ""
echo "##############################################################"
echo "# $(date) | Starting $appname"
echo "##############################################################"
echo ""

## Get current computer name
CurrentNameCheck=$(scutil --get ComputerName)
if [ "$?" = "0" ]; then
    echo " $(date) | Current computer name detected as $CurrentNameCheck"
else
    echo " $(date) | Unable to determine current name"
    exit 1
fi

## Get model name and derive code
ModelName=$(system_profiler SPHardwareDataType | awk /'Model Name: '/ | cut -d ':' -f2- | xargs)
if [ "$?" = "0" ]; then
    echo " $(date) | Retrieved model name: $ModelName"
else
    echo " $(date) | Unable to determine model name"
    exit 1
fi

case $ModelName in
    MacBook\ Air*)  ModelCode=MBA;;
    MacBook\ Pro*)  ModelCode=MBP;;
    MacBook*)       ModelCode=MB;;
    iMac*)          ModelCode=iMac;;
    Mac\ Pro*)      ModelCode=PRO;;
    Mac\ mini*)     ModelCode=MINI;;
    Mac\ Studio*)   ModelCode=MS;;
    Apple\ Virtual\ Machine*) ModelCode=VM;;
    *)              ModelCode=$(echo $ModelName | tr -d ' ' | cut -c1-4);;
esac

echo " $(date) | Model code set to $ModelCode"

## Get logged-in user
LoggedInUser=$(stat -f "%Su" /dev/console)
if [[ -z "$LoggedInUser" || "$LoggedInUser" == "root" ]]; then
    echo " $(date) | No user logged in or running as root, exiting"
    exit 1
fi
echo " $(date) | Logged-in user detected as $LoggedInUser"

## Format username - remove dots and capitalise each word
## e.g. user.name -> UserName
FormattedUser=$(echo "$LoggedInUser" | sed 's/\./ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1))substr($i,2)}1' | tr -d ' ')
echo " $(date) | Formatted username: $FormattedUser"

## Build new name
NewName="$ModelCode-$FormattedUser"
echo " $(date) | Generated new name: $NewName"

## Check if rename is necessary
if [[ "$CurrentNameCheck" == "$NewName" ]]; then
    echo " $(date) | Rename not required, already set to [$CurrentNameCheck]"
    exit 0
fi

## Set ComputerName
scutil --set ComputerName "$NewName"
if [ "$?" = "0" ]; then
    echo " $(date) | ComputerName changed from $CurrentNameCheck to $NewName"
else
    echo " $(date) | Failed to set ComputerName"
    exit 1
fi

## Set HostName
scutil --set HostName "$NewName"
if [ "$?" = "0" ]; then
    echo " $(date) | HostName changed from $CurrentNameCheck to $NewName"
else
    echo " $(date) | Failed to set HostName"
    exit 1
fi

## Set LocalHostName
scutil --set LocalHostName "$NewName"
if [ "$?" = "0" ]; then
    echo " $(date) | LocalHostName changed from $CurrentNameCheck to $NewName"
else
    echo " $(date) | Failed to set LocalHostName"
    exit 1
fi

echo " $(date) | Device successfully renamed to $NewName"
exit 0
#!/bin/bash

############################################################################################
##
## Script to set user account profile picture
##
############################################################################################

appname="SetUserAvatar"
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

LoggedInUser=$(stat -f "%Su" /dev/console)
if [[ -z "$LoggedInUser" || "$LoggedInUser" == "root" ]]; then
    echo " $(date) | No user logged in or running as root, exiting"
    exit 1
fi
echo " $(date) | Logged-in user detected as $LoggedInUser"

## Determine which avatar to use
if [[ "$LoggedInUser" == "itadmin" ]]; then
    AvatarURL="https://raw.githubusercontent.com/rangioraborough/intune/main/assets/macOS/login-icons/admin.png"
    echo " $(date) | Using admin avatar"
else
    AvatarURL="https://raw.githubusercontent.com/rangioraborough/intune/main/assets/macOS/login-icons/teacher.png"
    echo " $(date) | Using teacher avatar"
fi

## Store avatar permanently on disk
AvatarDir="/Library/RBS/Avatars"
mkdir -p "$AvatarDir"
AvatarPath="$AvatarDir/$LoggedInUser.png"

curl -L -o "$AvatarPath" "$AvatarURL"
if [ "$?" = "0" ]; then
    echo " $(date) | Avatar downloaded to $AvatarPath"
else
    echo " $(date) | Failed to download avatar"
    exit 1
fi

## Set the avatar
dscl . delete /Users/$LoggedInUser jpegphoto
sleep 1
dscl . delete /Users/$LoggedInUser Picture
sleep 1
dscl . create /Users/$LoggedInUser Picture "$AvatarPath"
if [ "$?" = "0" ]; then
    echo " $(date) | Avatar set successfully for $LoggedInUser"
else
    echo " $(date) | Failed to set avatar"
    exit 1
fi

echo " $(date) | Avatar script complete"
exit 0
#!/bin/bash

############################################################################################
##
## Script to configure Finder and Desktop settings
##
############################################################################################

appname="ConfigureFinder"
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

## Get user home directory
UserHome=$(dscl . read /Users/$LoggedInUser NFSHomeDirectory | awk '{print $2}')
echo " $(date) | User home directory: $UserHome"

##############################################################
## Finder General Settings
##############################################################

## New Finder windows open to user home folder
sudo -u "$LoggedInUser" defaults write com.apple.finder NewWindowTarget -string "PfHm"
sudo -u "$LoggedInUser" defaults write com.apple.finder NewWindowTargetPath -string "file://$UserHome/"
echo " $(date) | New Finder windows set to home folder"

## Show hard disks on desktop
sudo -u "$LoggedInUser" defaults write com.apple.finder ShowHardDrivesOnDesktop -bool true
echo " $(date) | Show hard disks on desktop enabled"

## Show external disks on desktop
sudo -u "$LoggedInUser" defaults write com.apple.finder ShowExternalHardDrivesOnDesktop -bool true
echo " $(date) | Show external disks on desktop enabled"

## Show CDs DVDs and iPods on desktop
sudo -u "$LoggedInUser" defaults write com.apple.finder ShowRemovableMediaOnDesktop -bool true
echo " $(date) | Show removable media on desktop enabled"

## Show connected servers on desktop
sudo -u "$LoggedInUser" defaults write com.apple.finder ShowMountedServersOnDesktop -bool true
echo " $(date) | Show connected servers on desktop enabled"

## Open folders in tabs instead of new windows
sudo -u "$LoggedInUser" defaults write com.apple.finder FinderSpawnTab -bool true
echo " $(date) | Open folders in tabs enabled"

##############################################################
## Finder View Settings
##############################################################

## Show status bar
sudo -u "$LoggedInUser" defaults write com.apple.finder ShowStatusBar -bool true
echo " $(date) | Status bar enabled"

## Show path bar
sudo -u "$LoggedInUser" defaults write com.apple.finder ShowPathbar -bool true
echo " $(date) | Path bar enabled"

## Show full path in title bar
sudo -u "$LoggedInUser" defaults write com.apple.finder _FXShowPosixPathInTitle -bool true
echo " $(date) | Full path in title bar enabled"

## Default to list view
sudo -u "$LoggedInUser" defaults write com.apple.finder FXPreferredViewStyle -string "Nlsv"
echo " $(date) | Default view set to list"

## Always open in list view
sudo -u "$LoggedInUser" defaults write com.apple.finder FXPreferredViewStyle -string "Nlsv"
echo " $(date) | Always open in list view enabled"

##############################################################
## List View Settings
##############################################################

sudo -u "$LoggedInUser" defaults write com.apple.finder StandardViewSettings -dict-add ListViewSettings "
<dict>
    <key>columns</key>
    <dict>
        <key>dateModified</key>
        <dict>
            <key>visible</key>
            <true/>
            <key>width</key>
            <integer>181</integer>
        </dict>
        <key>dateCreated</key>
        <dict>
            <key>visible</key>
            <false/>
        </dict>
        <key>size</key>
        <dict>
            <key>visible</key>
            <true/>
            <key>width</key>
            <integer>97</integer>
        </dict>
        <key>kind</key>
        <dict>
            <key>visible</key>
            <true/>
            <key>width</key>
            <integer>115</integer>
        </dict>
        <key>version</key>
        <dict>
            <key>visible</key>
            <false/>
        </dict>
        <key>comments</key>
        <dict>
            <key>visible</key>
            <false/>
        </dict>
    </dict>
    <key>iconSize</key>
    <integer>16</integer>
    <key>textSize</key>
    <integer>13</integer>
    <key>useRelativeDates</key>
    <true/>
    <key>calculateAllSizes</key>
    <false/>
    <key>showIconPreview</key>
    <true/>
    <key>sortColumn</key>
    <string>name</string>
    <key>ascending</key>
    <true/>
</dict>"
echo " $(date) | List view settings configured"

##############################################################
## Desktop Settings
##############################################################

## Enable stacks
sudo -u "$LoggedInUser" defaults write com.apple.finder DesktopViewSettings -dict-add GroupBy -string "Kind"
sudo -u "$LoggedInUser" defaults write com.apple.finder DesktopViewSettings -dict-add SortBy -string "Kind"
echo " $(date) | Desktop stacks enabled"

## Icon size 64x64
sudo -u "$LoggedInUser" defaults write com.apple.finder DesktopViewSettings -dict-add IconSize -int 64
echo " $(date) | Desktop icon size set to 64"

## Text size 12
sudo -u "$LoggedInUser" defaults write com.apple.finder DesktopViewSettings -dict-add FontSize -int 12
echo " $(date) | Desktop text size set to 12"

## Label position right
sudo -u "$LoggedInUser" defaults write com.apple.finder DesktopViewSettings -dict-add LabelOnBottom -bool false
echo " $(date) | Desktop label position set to right"

## Show item info
sudo -u "$LoggedInUser" defaults write com.apple.finder DesktopViewSettings -dict-add ShowItemInfo -bool true
echo " $(date) | Show item info enabled"

## Show icon preview
sudo -u "$LoggedInUser" defaults write com.apple.finder DesktopViewSettings -dict-add ShowIconPreview -bool true
echo " $(date) | Show icon preview enabled"

##############################################################
## Sidebar Settings
##############################################################

## Show Library folder
sudo -u "$LoggedInUser" chflags nohidden "$UserHome/Library"
echo " $(date) | Library folder unhidden"

## Show recent tags - disable
sudo -u "$LoggedInUser" defaults write com.apple.finder ShowRecentTags -bool false
echo " $(date) | Recent tags disabled"

##############################################################
## Restart Finder
##############################################################

sudo -u "$LoggedInUser" killall Finder
echo " $(date) | Finder restarted"

echo " $(date) | Finder configuration complete"
exit 0
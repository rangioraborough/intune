#!/bin/bash

############################################################################################
##
## Script to create a hidden local admin account
##
############################################################################################

appname="CreateAdminAccount"
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

## Define your admin account details here
ADMIN_USERNAME="itadmin"
ADMIN_PASSWORD=""
ADMIN_FULLNAME="IT Admin"

## Check if account already exists
if id "$ADMIN_USERNAME" &>/dev/null; then
    echo " $(date) | Account $ADMIN_USERNAME already exists, exiting"
    exit 0
fi

## Create the account
sysadminctl -addUser "$ADMIN_USERNAME" -fullName "$ADMIN_FULLNAME" -password "$ADMIN_PASSWORD" -admin
if [ "$?" = "0" ]; then
    echo " $(date) | Account $ADMIN_USERNAME created successfully"
else
    echo " $(date) | Failed to create account $ADMIN_USERNAME"
    exit 1
fi

## Hide the account from the login screen
dscl . create /Users/$ADMIN_USERNAME IsHidden 1
if [ "$?" = "0" ]; then
    echo " $(date) | Account $ADMIN_USERNAME hidden from login screen"
else
    echo " $(date) | Failed to hide account $ADMIN_USERNAME"
    exit 1
fi

echo " $(date) | Admin account setup complete"
exit 0
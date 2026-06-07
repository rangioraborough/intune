#!/bin/bash
defaults write /Library/Preferences/com.microsoft.autoupdate2 EnableAutoUpdate -bool false
defaults write /Library/Preferences/com.microsoft.autoupdate2 EnableCheckForUpdates -bool false
defaults write /Library/Preferences/com.microsoft.autoupdate2 StartDaemonOnAppLaunch -bool false
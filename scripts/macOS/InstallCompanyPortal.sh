#!/bin/bash

# Install Microsoft Intune Company Portal for macOS
# Bypasses Intune app-detection bug where AutoUpdate is mistaken for Company Portal

PKG_URL="https://go.microsoft.com/fwlink/?linkid=853070"
PKG_PATH="/tmp/CompanyPortal.pkg"

# Check if already installed (real check, by actual bundle)
if [ -d "/Applications/Company Portal.app" ]; then
    echo "Company Portal already installed. Exiting."
    exit 0
fi

echo "Downloading Company Portal..."
curl -L -o "$PKG_PATH" "$PKG_URL"

if [ $? -ne 0 ]; then
    echo "Download failed."
    exit 1
fi

echo "Installing Company Portal..."
installer -pkg "$PKG_PATH" -target /

if [ $? -eq 0 ]; then
    echo "Company Portal installed successfully."
    rm -f "$PKG_PATH"
    exit 0
else
    echo "Install failed."
    exit 1
fi
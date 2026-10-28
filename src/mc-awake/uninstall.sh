#!/bin/bash
# Fully removes McAwake and restores normal macOS sleep behavior.
# Asks for your admin password once (to remove the Smart Auto daemon,
# if installed, and reset the sleep switch).
set -u

echo "This will quit McAwake, restore normal sleep, and remove the app."
read -r -p "Proceed? [y/N] " answer
if [[ ! "$answer" =~ ^[Yy]$ ]]; then
  echo "Cancelled."
  exit 0
fi

pkill -f "McAwake.app/Contents/MacOS/McAwake" 2>/dev/null

osascript -e 'do shell script "launchctl bootout system/com.mcawake.auto 2>/dev/null; rm -f /Library/LaunchDaemons/com.mcawake.auto.plist /usr/local/bin/mcawake-auto.sh; rm -rf \"/Library/Application Support/McAwake\" /var/db/com.mcawake; pmset -a disablesleep 0; true" with administrator privileges' \
  || { echo "Password prompt cancelled — nothing removed."; exit 1; }

rm -rf "/Applications/McAwake.app"

echo "McAwake removed. Normal sleep behavior restored."
echo "(If 'McAwake' still shows under System Settings > General > Login Items, remove it there.)"

#!/bin/bash
# Fully removes McAwake and restores normal macOS sleep behavior.
# Asks for your admin password once (to remove the Smart Auto daemon,
# if installed, and reset the sleep switch).
set -u

MC_AWAKE_LANGUAGE=$(/usr/bin/defaults read com.mcawake.app McAwakeLanguage 2>/dev/null || true)
localized() {
  if [ "$MC_AWAKE_LANGUAGE" = "en" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi
}

echo "$(localized "此操作会退出 McAwake、恢复正常睡眠并移除应用。" "This will quit McAwake, restore normal sleep, and remove the app.")"
read -r -p "$(localized "是否继续？[y/N] " "Proceed? [y/N] ")" answer
if [[ ! "$answer" =~ ^[Yy]$ ]]; then
  echo "$(localized "已取消。" "Cancelled.")"
  exit 0
fi

pkill -f "McAwake.app/Contents/MacOS/McAwake" 2>/dev/null

osascript -e 'do shell script "launchctl bootout system/com.mcawake.auto 2>/dev/null; rm -f /Library/LaunchDaemons/com.mcawake.auto.plist /usr/local/bin/mcawake-auto.sh; rm -rf \"/Library/Application Support/McAwake\" /var/db/com.mcawake; pmset -a disablesleep 0; true" with administrator privileges' \
  || { echo "$(localized "已取消管理员授权，未移除任何内容。" "Password prompt cancelled — nothing removed.")"; exit 1; }

rm -rf "/Applications/McAwake.app"

echo "$(localized "已移除 McAwake，并恢复正常睡眠。" "McAwake removed. Normal sleep behavior restored.")"
echo "$(localized "（如果“系统设置 > 通用 > 登录项”中仍显示 McAwake，请在其中移除。）" "(If 'McAwake' still shows under System Settings > General > Login Items, remove it there.)")"

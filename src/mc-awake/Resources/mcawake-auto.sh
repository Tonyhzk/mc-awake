#!/bin/bash
# McAwake daemon (installed by McAwake.app, runs as root).
#
# Mode "auto":   awake on AC power, normal sleep on battery.
# Mode "always": awake everywhere — except the low-battery guard: below
#                ${LOW}% on battery, normal sleep is restored so a
#                forgotten unplugged Mac can't run itself flat (or hot in
#                a closed bag). Re-arms at ${REARM}% or when AC returns.
#
# 自动或持续唤醒模式在合盖时恢复睡眠权限，会立即执行 pmset sleepnow。
#
# State changes are logged to /var/log/mcawake.log (tiny volume — one
# line per state change). Not the unified log: logger(1) messages don't
# reliably surface in `log show` on modern macOS, verified live.
#
set -u
[ "${1:-}" = "--uid" ] || exit 1
OWNER_UID="${2:-}"
case "$OWNER_UID" in ''|*[!0-9]*) exit 1 ;; esac

STATE_DIR="/var/db/com.mcawake"
MODE_FILE="$STATE_DIR/mode"
CONTROL="$STATE_DIR/control"
LOW=15
REARM=18
LOGFILE="/var/log/mcawake.log"

log() { { echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE"; } 2>/dev/null || true; }

/bin/rm -f "$CONTROL"
/usr/bin/mkfifo -m 600 "$CONTROL" || exit 1
/usr/sbin/chown "$OWNER_UID" "$CONTROL" || exit 1
exec 3<> "$CONTROL" || exit 1

MODE="normal"
if [ -f "$MODE_FILE" ]; then
  IFS= read -r saved_mode < "$MODE_FILE" || true
  case "${saved_mode:-}" in normal|auto|always) MODE="$saved_mode" ;; esac
fi
normal_pending=1
log "daemon started (mode=$MODE)"

while true; do
  cur=$(/usr/bin/pmset -g | /usr/bin/awk '/SleepDisabled/{print $2}')
  if [ "$MODE" = "normal" ]; then
    if [ "$normal_pending" = 1 ] && [ "$cur" != 0 ]; then
      /usr/bin/pmset -a disablesleep 0
      log "mode=normal: disablesleep $cur -> 0"
    fi
    normal_pending=0
  else
    if /usr/bin/pmset -g ps | /usr/bin/head -1 | /usr/bin/grep -q "AC Power"; then
      power="ac"
      pct=""
      want=1
    else
      power="battery"
      pct=$(/usr/bin/pmset -g ps | /usr/bin/grep -Eo '[0-9]+%' | /usr/bin/head -1 | /usr/bin/tr -d '%')
      [ -z "$pct" ] && pct=100   # no battery (desktop Mac): guard never trips
      if [ "$MODE" = "always" ]; then
        if [ "$pct" -le "$LOW" ]; then
          want=0
        elif [ "$pct" -ge "$REARM" ]; then
          want=1
        else
          want="$cur"   # hysteresis band: hold current state, no flapping
        fi
      else
        want=0
      fi
    fi

    if [ "$cur" != "$want" ]; then
      /usr/bin/pmset -a disablesleep "$want"
      log "mode=$MODE power=$power${pct:+ pct=$pct%}: disablesleep $cur -> $want"
      if [ "$want" = "0" ] && /usr/sbin/ioreg -r -k AppleClamshellState -d 1 \
          | /usr/bin/grep -q '"AppleClamshellState" = Yes'; then
        log "lid is closed — forcing sleep now"
        /usr/bin/pmset sleepnow
      fi
    fi
  fi

  if IFS= read -r -n 32 -t 20 request <&3; then
    case "$request" in
      normal|auto|always)
        MODE="$request"
        printf '%s\n' "$MODE" > "$MODE_FILE"
        normal_pending=1
        ;;
    esac
  fi
done

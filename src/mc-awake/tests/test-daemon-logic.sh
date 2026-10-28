#!/bin/bash
# McAwake daemon logic tests.
#
# Runs ONE cycle of Resources/mcawake-auto.sh against mocked system tools
# (pmset / ioreg / logger) and asserts exactly which privileged commands it
# issued for each power/battery/lid scenario. No root, no real pmset calls.
#
#   bash tests/test-daemon-logic.sh
set -u
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
DAEMON_PID=""
trap 'if [ -n "$DAEMON_PID" ]; then kill "$DAEMON_PID" 2>/dev/null || true; wait "$DAEMON_PID" 2>/dev/null || true; fi' EXIT
mkdir -p "$WORK/bin"

sed -e 's|/usr/bin/pmset|pmset|g; s|/usr/sbin/ioreg|ioreg|g; s|/usr/sbin/chown|chown|g' \
    -e 's|/usr/bin/head|head|g; s|/usr/bin/grep|grep|g; s|/usr/bin/tr|tr|g; s|/usr/bin/awk|awk|g' \
    -e 's|STATE_DIR="/var/db/com.mcawake"|STATE_DIR="$TEST_STATE"|' \
    -e 's|LOGFILE="/var/log/mcawake.log"|LOGFILE="$TEST_STATE/daemon.log"|' \
    Resources/mcawake-auto.sh > "$WORK/live-daemon.sh"
sed '/  if IFS= read -r -n 32 -t 20 request <&3; then/,$d' \
    "$WORK/live-daemon.sh" > "$WORK/one-cycle.sh"
printf '  exit 0\ndone\n' >> "$WORK/one-cycle.sh"

cat > "$WORK/bin/pmset" <<'EOF'
#!/bin/bash
if [ "$1" = "-g" ] && [ "${2:-}" = "ps" ]; then
  if [ "$MOCK_AC" = "1" ]; then echo "Now drawing from 'AC Power'"; else echo "Now drawing from 'Battery Power'"; fi
  [ -n "$MOCK_PCT" ] && echo " -InternalBattery-0 (id=123)	${MOCK_PCT}%; discharging; 3:00 remaining"
elif [ "$1" = "-g" ]; then
  echo " SleepDisabled		${MOCK_CUR}"
elif [ "$1" = "-a" ]; then
  echo "disablesleep $3" >> "$MOCK_LOG"
elif [ "$1" = "sleepnow" ]; then
  echo "sleepnow" >> "$MOCK_LOG"
fi
EOF

cat > "$WORK/bin/ioreg" <<'EOF'
#!/bin/bash
echo "\"AppleClamshellState\" = ${MOCK_LID}"
EOF

cat > "$WORK/bin/chown" <<'EOF'
#!/bin/bash
exit 0
EOF

chmod +x "$WORK/bin/"*

PASS=0
FAIL=0

cp Resources/com.mcawake.auto.plist "$WORK/installed.plist"
uid=$(id -u)
if /usr/libexec/PlistBuddy -c "Set :ProgramArguments:3 $uid" "$WORK/installed.plist" && \
   [ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:3' "$WORK/installed.plist")" = "$uid" ] && \
   ! /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:4' "$WORK/installed.plist" >/dev/null 2>&1; then
  PASS=$((PASS+1))
  echo "PASS  daemon plist has exactly four arguments and the correct uid"
else
  FAIL=$((FAIL+1))
  echo "FAIL  daemon plist uid or argument count is incorrect"
fi

# check <mode> <ac> <pct> <cur> <lid Yes|No> <expected ;-joined privileged calls or "none">
check() {
  local mode=$1 ac=$2 pct=$3 cur=$4 lid=$5 expect=$6
  export TEST_STATE="$WORK/case-$((PASS + FAIL + 1))"
  mkdir -p "$TEST_STATE"
  printf '%s\n' "$mode" > "$TEST_STATE/mode"
  export MOCK_AC=$ac MOCK_PCT=$pct MOCK_CUR=$cur MOCK_LID=$lid MOCK_LOG="$TEST_STATE/calls.txt"
  PATH="$WORK/bin:$PATH" bash "$WORK/one-cycle.sh" --uid "$(id -u)"
  local got
  got=$(paste -sd';' "$MOCK_LOG" 2>/dev/null || true)
  [ -z "$got" ] && got="none"
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS+1))
    echo "PASS  mode=$mode ac=$ac pct=${pct:-n/a} cur=$cur lid=$lid -> $got"
  else
    FAIL=$((FAIL+1))
    echo "FAIL  mode=$mode ac=$ac pct=${pct:-n/a} cur=$cur lid=$lid -> got '$got', expected '$expect'"
  fi
}

echo "== always mode =="
check always 1 50 0 No  "disablesleep 1"                 # AC: awake
check always 0 50 0 No  "disablesleep 1"                 # battery, healthy: awake
check always 0 15 1 No  "disablesleep 0"                 # guard trips, lid open: no force
check always 0 15 1 Yes "disablesleep 0;sleepnow"        # guard trips, lid closed: force sleep
check always 0 16 0 No  "none"                           # hysteresis band holds 0
check always 0 17 1 No  "none"                           # hysteresis band holds 1
check always 0 18 0 No  "disablesleep 1"                 # re-arms at 18%
check always 0 "" 0 No  "disablesleep 1"                 # no battery reading: treat as full

echo "== auto mode =="
check auto 1 50 0 No  "disablesleep 1"                   # AC: awake
check auto 0 50 1 No  "disablesleep 0"                   # battery: normal sleep
check auto 0 50 1 Yes "disablesleep 0;sleepnow"          # unplugged with lid closed: force sleep
check auto 0 50 0 No  "none"                             # battery, already normal: no-op
check auto 1 50 1 Yes "none"                             # AC, already awake: no-op, no force

echo "== normal mode =="
check normal 1 50 1 Yes "disablesleep 0"
check normal 0 50 0 No  "none"

echo "== control channel =="
export TEST_STATE="$WORK/live" MOCK_AC=1 MOCK_PCT=50 MOCK_CUR=0 MOCK_LID=No
mkdir -p "$TEST_STATE"
export MOCK_LOG="$TEST_STATE/calls.txt"
printf 'normal\n' > "$TEST_STATE/mode"
PATH="$WORK/bin:$PATH" bash "$WORK/live-daemon.sh" --uid "$(id -u)" > "$TEST_STATE/output.txt" 2>&1 &
DAEMON_PID=$!

wait_for() {
  local expected=$1 current="" i
  for ((i=0; i<100; i++)); do
    if [ "$expected" = fifo ]; then
      [ -p "$TEST_STATE/control" ] && return 0
    elif [ -f "$TEST_STATE/mode" ]; then
      IFS= read -r current < "$TEST_STATE/mode" || true
      [ "$current" = "$expected" ] && return 0
    fi
    kill -0 "$DAEMON_PID" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}

if wait_for fifo && [ "$(stat -f '%Lp' "$TEST_STATE/control")" = 600 ]; then
  PASS=$((PASS+1))
  echo "PASS  control FIFO is restricted to its owner"
  for mode in always auto normal always; do
    printf '%s\n' "$mode" > "$TEST_STATE/control"
    if wait_for "$mode"; then
      PASS=$((PASS+1))
      echo "PASS  control selected $mode"
    else
      FAIL=$((FAIL+1))
      echo "FAIL  control did not select $mode"
      break
    fi
  done
  printf '%s\n' 'invalid-mode' > "$TEST_STATE/control"
  sleep 0.1
  IFS= read -r current < "$TEST_STATE/mode" || true
  if [ "$current" = always ]; then
    PASS=$((PASS+1))
    echo "PASS  invalid request did not change mode"
  else
    FAIL=$((FAIL+1))
    echo "FAIL  invalid request changed mode to $current"
  fi
  printf 'auto\nnormal\n' > "$TEST_STATE/control"
  if wait_for normal; then
    PASS=$((PASS+1))
    echo "PASS  queued mode changes reach the final selection"
  else
    FAIL=$((FAIL+1))
    echo "FAIL  queued mode changes did not reach the final selection"
  fi
else
  FAIL=$((FAIL+1))
  echo "FAIL  control FIFO unavailable or permissions incorrect"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

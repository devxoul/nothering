#!/bin/bash
# Apply a risky network change with automatic rollback.
#
#   scripts/failsafe.sh '<apply command>' '<revert command>' [timeout_seconds]
#
# The watchdog runs detached from the calling shell and reverts when either:
#   - the probe URL fails 3 times in a row (checked every 5s), or
#   - the timeout elapses without `touch $FAILSAFE_CONFIRM`.
set -euo pipefail

apply_cmd=${1:?apply command required}
revert_cmd=${2:?revert command required}
timeout=${3:-120}
probe=${FAILSAFE_PROBE:-https://api.anthropic.com}
confirm=${FAILSAFE_CONFIRM:-/tmp/nothering-failsafe.confirm}
log=${FAILSAFE_LOG:-/tmp/nothering-failsafe.log}

rm -f "$confirm"
: > "$log"

nohup bash -c '
  revert_cmd=$1 timeout=$2 probe=$3 confirm=$4
  revert() { echo "$(date +%T) revert: $1"; bash -c "$revert_cmd"; exit 0; }
  failures=0
  deadline=$((SECONDS + timeout))
  while :; do
    sleep 5
    [ -e "$confirm" ] && { echo "$(date +%T) confirmed, watchdog exiting"; exit 0; }
    [ $SECONDS -ge $deadline ] && revert "timeout"
    if curl -m 5 -s -o /dev/null "$probe"; then failures=0; else failures=$((failures + 1)); fi
    echo "$(date +%T) probe failures=$failures"
    [ $failures -ge 3 ] && revert "probe failed"
  done
' failsafe "$revert_cmd" "$timeout" "$probe" "$confirm" >> "$log" 2>&1 &
disown

echo "watchdog pid $! (log: $log, confirm: touch $confirm)"
bash -c "$apply_cmd"

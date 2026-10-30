# shellcheck shell=bash
# Loaded into wait.sh through BASH_ENV. Replaces sleep: instead of waiting, it
# moves the SECONDS clock forward, so deadlines run out right away, and runs
# the script of the test for this sleep, if any.
sleep() {
  local tick
  tick=$(($(cat "$FAKE_STATE/ticks/count" 2>/dev/null || echo 0) + 1))
  echo "$tick" >"$FAKE_STATE/ticks/count"
  echo "sleep $1" >>"$FAKE_STATE/calls.log"
  SECONDS=$((SECONDS + $1))
  if [ -f "$FAKE_STATE/ticks/$tick" ]; then
    bash "$FAKE_STATE/ticks/$tick"
  fi
  if [ -f "$FAKE_STATE/stop" ]; then
    exit 99
  fi
  if [ "$tick" -ge "${FAKE_MAX_TICKS:-100}" ]; then
    echo "fake sleep: more than ${FAKE_MAX_TICKS:-100} sleeps, wait.sh seems stuck" >&2
    exit 98
  fi
}

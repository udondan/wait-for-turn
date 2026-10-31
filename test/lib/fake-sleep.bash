# shellcheck shell=bash
# Loaded into wait.sh through BASH_ENV. wait.sh sleeps with `sleep n & wait $!`.
# The fake sleep runs in that background subshell and only notes how long to
# sleep. The fake wait then, in the shell of wait.sh, moves the SECONDS clock
# forward instead of waiting, so deadlines run out right away, and runs the
# script of the test for this sleep, if any. With FAKE_REAL_SLEEP set, sleep
# really sleeps, for tests that send a signal while wait.sh sleeps, and
# notes its pid in ticks/sleep_pid.
sleep() {
  echo "$1" >"$FAKE_STATE/ticks/sleeping"
  if [ -n "${FAKE_REAL_SLEEP:-}" ]; then
    echo "$BASHPID" >"$FAKE_STATE/ticks/sleep_pid"
    exec sleep "$1"
  fi
}

wait() {
  local tick seconds
  builtin wait "$@"
  seconds=$(cat "$FAKE_STATE/ticks/sleeping")
  tick=$(($(cat "$FAKE_STATE/ticks/count" 2>/dev/null || echo 0) + 1))
  echo "$tick" >"$FAKE_STATE/ticks/count"
  echo "sleep $seconds" >>"$FAKE_STATE/calls.log"
  if [ -n "${FAKE_REAL_SLEEP:-}" ]; then
    return 0
  fi
  SECONDS=$((SECONDS + seconds))
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

#!/usr/bin/env bash
# Runs the tests for bashcov: `bundle exec bashcov -- test/coverage.sh`.
#
# bashcov traces every bash process it starts, but bats must not be traced:
# its output formatter runs alongside the tests, their trace lines get mixed
# up and bashcov stops parsing. So tracing is switched off for bats here and
# run_wait (test/helpers.bash) switches it back on for wait.sh only.
set +x
export WAIT_FOR_TURN_COVERAGE=1
exec env -u SHELLOPTS bats "$(dirname "$0")" "$@"

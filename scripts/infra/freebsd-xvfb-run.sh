#!/usr/bin/env sh
set -eu

# Usage: freebsd-xvfb-run.sh <timeout-seconds> <executable-path> [args...]
TIMEOUT_SECONDS="${1:-15}"
shift || true

if [ $# -eq 0 ]; then
  echo "Error: No executable specified to run under Xvfb." >&2
  exit 2
fi

DISPLAY_NUM=99
while [ -e "/tmp/.X${DISPLAY_NUM}-lock" ] || [ -S "/tmp/.X11-unix/X${DISPLAY_NUM}" ]; do
  DISPLAY_NUM=$((DISPLAY_NUM + 1))
done

export DISPLAY=":${DISPLAY_NUM}"

echo "Starting Xvfb on display $DISPLAY..."
Xvfb "$DISPLAY" -screen 0 1024x768x24 >/dev/null 2>&1 &
XVFB_PID=$!

cleanup() {
  if [ -n "${XVFB_PID:-}" ]; then
    kill "$XVFB_PID" >/dev/null 2>&1 || true
    wait "$XVFB_PID" >/dev/null 2>&1 || true
  }
}
trap cleanup EXIT

# Brief pause to let Xvfb initialize sockets
sleep 1

echo "Running target application with timeout of ${TIMEOUT_SECONDS}s: $*"
set +e
timeout "${TIMEOUT_SECONDS}s" "$@"
code=$?
set -e


if [ "$code" = "124" ] || [ "$code" = "143" ]; then
  echo "Application stayed alive for the requested duration (${TIMEOUT_SECONDS}s)."
  exit 0
fi

exit "$code"
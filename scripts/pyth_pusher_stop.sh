#!/usr/bin/env bash
# Stop the Pyth price pusher started by scripts/pyth_pusher_start.sh.
set -uo pipefail

PIDF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/kora/pyth-pusher.pid"

if [[ -f "$PIDF" ]] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  pid="$(cat "$PIDF")"
  # The pusher leads its own process group.
  kill -- "-$pid" 2>/dev/null || kill "$pid"
  for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
  kill -0 "$pid" 2>/dev/null && { kill -9 -- "-$pid" 2>/dev/null || kill -9 "$pid"; }
  echo "pyth-pusher stopped"
else
  echo "pyth-pusher not running"
fi
rm -f "$PIDF"

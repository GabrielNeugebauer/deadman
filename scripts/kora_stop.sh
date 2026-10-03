#!/usr/bin/env bash
# Stop the Deadman Kora sponsor node. `--all` also stops the Redis container
# (usage counters persist in the deadman-kora-redis volume).
set -uo pipefail

KDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/kora"

for name in sponsor; do
  pidf="$KDIR/$name.pid"
  if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
    pid="$(cat "$pidf")"
    kill "$pid"
    for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid"
    echo "$name stopped"
  else
    echo "$name not running"
  fi
  rm -f "$pidf"
done

if [[ "${1:-}" == "--all" ]]; then
  docker stop deadman-kora-redis >/dev/null 2>&1 && echo "redis stopped"
fi

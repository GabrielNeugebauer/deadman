#!/usr/bin/env bash
# Stop the Deadman gateway (:8080 sponsor, :8081 paymaster) and the Kora
# nodes (:8090 sponsor, :8091-8093 paymaster tiers). `--all` also stops the Redis
# container (usage counters persist in the deadman-kora-redis volume; gateway
# counters in kora/gateway-usage.json and kora/paymaster-*.json).
set -uo pipefail

KDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/kora"

for name in gateway sponsor paymaster paymaster-account paymaster-basic; do
  pidf="$KDIR/$name.pid"
  if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
    pid="$(cat "$pidf")"
    # The gateway leads its own process group (dart wrapper + VM).
    kill -- "-$pid" 2>/dev/null || kill "$pid"
    for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
    kill -0 "$pid" 2>/dev/null && { kill -9 -- "-$pid" 2>/dev/null || kill -9 "$pid"; }
    echo "$name stopped"
  else
    echo "$name not running"
  fi
  rm -f "$pidf"
done

if [[ "${1:-}" == "--all" ]]; then
  docker stop deadman-kora-redis >/dev/null 2>&1 && echo "redis stopped"
fi

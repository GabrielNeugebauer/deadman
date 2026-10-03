#!/usr/bin/env bash
# Start the Deadman Kora sponsor node (:8080) in the background. It pays
# fees for guard-key check-ins and duress locks; owners pay their own SOL.
# Needs kora/.env (KORA_SIGNER_PRIVATE_KEY, optional RPC_URL, SPONSOR_API_KEY),
# the `kora` binary (kora-cli 2.0.5) and Docker for Redis.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KDIR="$ROOT/kora"
LOGS="$KDIR/logs"
REDIS_NAME="deadman-kora-redis"
mkdir -p "$LOGS"

[[ -f "$KDIR/.env" ]] || { echo "missing $KDIR/.env (see docs/KORA.md)" >&2; exit 1; }
set -a; source "$KDIR/.env"; set +a
: "${KORA_SIGNER_PRIVATE_KEY:?KORA_SIGNER_PRIVATE_KEY not set in kora/.env}"
RPC_URL="${RPC_URL:-https://api.devnet.solana.com}"

KORA_BIN="${KORA_BIN:-$(command -v kora || echo "$HOME/.cargo/bin/kora")}"
[[ -x "$KORA_BIN" ]] || { echo "kora binary not found; cargo install kora-cli --version 2.0.5 --locked" >&2; exit 1; }

# Redis backs the per-wallet usage limits. Bound to localhost, AOF-persisted.
if ! docker ps --format '{{.Names}}' | grep -qx "$REDIS_NAME"; then
  if docker ps -a --format '{{.Names}}' | grep -qx "$REDIS_NAME"; then
    docker start "$REDIS_NAME" >/dev/null
  else
    docker run -d --name "$REDIS_NAME" --restart unless-stopped \
      -p 127.0.0.1:6379:6379 -v deadman-kora-redis:/data \
      redis:7-alpine redis-server --appendonly yes >/dev/null
  fi
fi
for _ in $(seq 1 20); do
  docker exec "$REDIS_NAME" redis-cli ping 2>/dev/null | grep -q PONG && break
  sleep 0.5
done

start_node() {
  local name="$1" port="$2" api_key="${3:-}"
  local pidf="$KDIR/$name.pid"
  if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
    echo "$name already running (pid $(cat "$pidf"))"
    return
  fi
  # KORA_API_KEY / KORA_HMAC_SECRET override kora.toml, so set them per node only.
  env -u KORA_API_KEY -u KORA_HMAC_SECRET ${api_key:+KORA_API_KEY="$api_key"} \
    RUST_LOG="${RUST_LOG:-info}" \
    nohup "$KORA_BIN" --config "$KDIR/$name.toml" --rpc-url "$RPC_URL" \
      rpc start --signers-config "$KDIR/signers.toml" --port "$port" \
      >>"$LOGS/$name.log" 2>&1 &
  echo $! >"$pidf"
  for _ in $(seq 1 40); do
    if curl -sf "http://127.0.0.1:$port/liveness" >/dev/null; then
      echo "$name up on :$port (pid $(cat "$pidf")), log $LOGS/$name.log"
      return
    fi
    kill -0 "$(cat "$pidf")" 2>/dev/null || break
    sleep 0.5
  done
  echo "$name failed to start; last log lines:" >&2
  tail -n 20 "$LOGS/$name.log" >&2
  exit 1
}

start_node sponsor 8080 "${SPONSOR_API_KEY:-}"

LAN_IP="$(hostname -I | awk '{print $1}')"
echo "sponsor:   http://$LAN_IP:8080"

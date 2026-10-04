#!/usr/bin/env bash
# Start the Deadman Kora stack in the background:
# - sponsor:   Kora on :8090 (free), public gateway :8080 (guard pulse/lockdown)
# - paymaster: three Kora nodes, one fixed USDC price each, behind the
#   public gateway :8081 (owner transactions whose last instruction pays
#   USDC; the gateway picks the node by what Kora funds):
#     :8091 plan    3.00 USDC  Kora funds a new vault's rent (+ <= 2 ATAs)
#     :8092 account 1.00 USDC  Kora funds <= 2 token accounts
#     :8093 basic   0.02 USDC  network fee only
# Both Kora nodes need an API key that only the gateway (tool/kora_gateway.dart,
# one process serving both ports) holds.
# Needs kora/.env (KORA_SIGNER_PRIVATE_KEY, optional RPC_URL and
# TEST_USDC_MINT; SPONSOR_API_KEY and PAYMASTER_API_KEY are generated on first
# run), the `kora` binary (kora-cli 2.0.5), Dart and Docker for Redis.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KDIR="$ROOT/kora"
LOGS="$KDIR/logs"
REDIS_NAME="deadman-kora-redis"
mkdir -p "$LOGS"

[[ -f "$KDIR/.env" ]] || { echo "missing $KDIR/.env (see docs/KORA.md)" >&2; exit 1; }
for var in SPONSOR_API_KEY PAYMASTER_API_KEY; do
  if ! grep -qE "^$var=.+" "$KDIR/.env"; then
    sed -i "/^$var=/d" "$KDIR/.env"
    (umask 077; printf '%s=%s\n' "$var" "$(openssl rand -hex 32)" >>"$KDIR/.env")
    chmod 600 "$KDIR/.env"
    echo "generated $var in kora/.env"
  fi
done
set -a; source "$KDIR/.env"; set +a
: "${KORA_SIGNER_PRIVATE_KEY:?KORA_SIGNER_PRIVATE_KEY not set in kora/.env}"
: "${SPONSOR_API_KEY:?SPONSOR_API_KEY not set in kora/.env}"
: "${PAYMASTER_API_KEY:?PAYMASTER_API_KEY not set in kora/.env}"
RPC_URL="${RPC_URL:-https://api.devnet.solana.com}"

# Render one paymaster config per price tier from kora/paymaster.toml (the
# plan tier): price, fee-payer outflow cap, whether Kora may fund accounts,
# metrics port. Optionally accept a second (test) USDC mint.
if [[ -n "${TEST_USDC_MINT:-}" ]]; then
  [[ "$TEST_USDC_MINT" =~ ^[1-9A-HJ-NP-Za-km-z]{32,44}$ ]] \
    || { echo "TEST_USDC_MINT is not a base58 address" >&2; exit 1; }
  echo "paymaster also accepts TEST_USDC_MINT $TEST_USDC_MINT"
fi
render_tier() {
  local name="$1" port="$2" amount="$3" max_lamports="$4" create="$5"
  local out="$KDIR/paymaster-$name.run.toml"
  sed -E \
    -e "s/^amount = [0-9]+/amount = $amount/" \
    -e "s/^max_allowed_lamports = [0-9_]+/max_allowed_lamports = $max_lamports/" \
    -e "s/^allow_create_account = (true|false)/allow_create_account = $create/" \
    -e "s/^port = [0-9]+/port = $port/" \
    "$KDIR/paymaster.toml" >"$out"
  if [[ -n "${TEST_USDC_MINT:-}" ]]; then
    sed -i -E "s/^(allowed_(tokens|spl_paid_tokens) = \[[^]]*)\]/\1, \"$TEST_USDC_MINT\"]/" "$out"
  fi
}
# Outflow caps: vault rent 7_345_680 (1318 bytes), ATA rent 2_039_280
# (165 bytes), network fee <= 50_000 (gateway cap).
render_tier plan    8091 3000000 11500000 true
render_tier account 8092 1000000 4150000  true
render_tier basic   8093 20000   60000    false
PM_CONFIG="$KDIR/paymaster-plan.run.toml"

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
  local name="$1" port="$2" api_key="$3" config="$4"
  local pidf="$KDIR/$name.pid"
  if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
    echo "$name already running (pid $(cat "$pidf"))"
    return
  fi
  # KORA_API_KEY / KORA_HMAC_SECRET override kora.toml, so set them per node only.
  env -u KORA_API_KEY -u KORA_HMAC_SECRET ${api_key:+KORA_API_KEY="$api_key"} \
    RUST_LOG="${RUST_LOG:-info}" \
    nohup "$KORA_BIN" --config "$config" --rpc-url "$RPC_URL" \
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

start_node sponsor 8090 "$SPONSOR_API_KEY" "$KDIR/sponsor.toml"

# The paymaster's USDC payment ATA(s) on the signer; a no-op once they exist.
if ! "$KORA_BIN" --config "$PM_CONFIG" --rpc-url "$RPC_URL" \
    rpc initialize-atas --signers-config "$KDIR/signers.toml" \
    >>"$LOGS/paymaster.log" 2>&1; then
  echo "warning: kora rpc initialize-atas failed (see $LOGS/paymaster.log); USDC payments fail until the payment ATA exists" >&2
fi
start_node paymaster 8091 "$PAYMASTER_API_KEY" "$PM_CONFIG"
start_node paymaster-account 8092 "$PAYMASTER_API_KEY" "$KDIR/paymaster-account.run.toml"
start_node paymaster-basic 8093 "$PAYMASTER_API_KEY" "$KDIR/paymaster-basic.run.toml"

# Public entry, one process serving :8080 (sponsor) and :8081 (paymaster).
# It reads SPONSOR_API_KEY, PAYMASTER_API_KEY and RPC_URL from the environment.
start_gateway() {
  local pidf="$KDIR/gateway.pid"
  if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
    echo "gateway already running (pid $(cat "$pidf"))"
    return
  fi
  # Own process group (the Flutter `dart` wrapper forks the VM), so
  # kora_stop.sh can stop both with one signal.
  RPC_URL="$RPC_URL" GATEWAY_PORT=8080 KORA_UPSTREAM=http://127.0.0.1:8090 \
    GATEWAY_STATE="$KDIR/gateway-usage.json" \
    PAYMASTER_PORT=8081 PAYMASTER_UPSTREAM=http://127.0.0.1:8091 \
    PAYMASTER_ACCOUNT_UPSTREAM=http://127.0.0.1:8092 \
    PAYMASTER_BASIC_UPSTREAM=http://127.0.0.1:8093 \
    PAYMASTER_STATE="$KDIR/paymaster-usage.json" \
    PAYMASTER_CREATES_STATE="$KDIR/paymaster-creates.json" \
    setsid bash -c 'cd "$1" && exec dart run tool/kora_gateway.dart' _ "$ROOT" \
    </dev/null >>"$LOGS/gateway.log" 2>&1 &
  echo $! >"$pidf"
  for _ in $(seq 1 240); do
    if curl -sf "http://127.0.0.1:8080/liveness" >/dev/null &&
       curl -sf "http://127.0.0.1:8081/liveness" >/dev/null; then
      echo "gateway up on :8080 and :8081 (pid $(cat "$pidf")), log $LOGS/gateway.log"
      return
    fi
    kill -0 "$(cat "$pidf")" 2>/dev/null || break
    sleep 0.5
  done
  echo "gateway failed to start; last log lines:" >&2
  tail -n 20 "$LOGS/gateway.log" >&2
  exit 1
}

start_gateway

LAN_IP="$(hostname -I | awk '{print $1}')"
echo "sponsor   (public gateway): http://$LAN_IP:8080"
echo "paymaster (public gateway): http://$LAN_IP:8081"

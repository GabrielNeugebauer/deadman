#!/usr/bin/env bash
# Start the Deadman Kora stack in the background:
# - sponsor:   Kora on :8090 (free), public gateway :8080 (guard pulse/lockdown,
#   and a beneficiary's own SOL claim)
# - paymaster: three Kora nodes, one fixed USDC price each, behind the
#   public gateway :8081 (owner transactions whose last instruction pays
#   USDC; the gateway picks the node by what Kora funds):
#     :8091 plan    3.00 USDC  Kora funds a new vault's rent (+ <= 2 ATAs)
#     :8092 account 0.50 USDC  Kora funds <= 2 token accounts
#     :8093 basic   0.02 USDC  network fee only
# Both Kora nodes need an API key that only the gateway (tool/kora_gateway.dart,
# one process serving both ports) holds.
# Needs kora/.env (KORA_SIGNER_PRIVATE_KEY, optional RPC_URL and
# TEST_USDC_MINT; SPONSOR_API_KEY and PAYMASTER_API_KEY are generated on first
# run), the `kora` binary (kora-cli 2.0.5), Dart and Docker for Redis.
#
# CLUSTER=mainnet-beta CONFIRM_MAINNET=yes scripts/kora_start.sh runs the
# mainnet stack instead: kora/sponsor.mainnet.toml and ONE margin-priced
# paymaster node (kora/paymaster.mainnet.toml, :8091) for every tier, with
# secrets from kora/.env.mainnet (KORA_SIGNER_PRIVATE_KEY, RPC_URL and
# JUPITER_API_KEY required; the API keys are generated). Counters go to
# kora/mainnet-*.json and Redis DBs 2-3. It spends mainnet SOL: the payment
# ATA, and every fee and rent Kora pays.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KDIR="$ROOT/kora"
LOGS="$KDIR/logs"
REDIS_NAME="deadman-kora-redis"
mkdir -p "$LOGS"

CLUSTER="${CLUSTER:-devnet}"
case "$CLUSTER" in
  devnet)
    ENV_FILE="$KDIR/.env"
    STATE="$KDIR"
    SPONSOR_CONFIG="$KDIR/sponsor.toml"
    ;;
  mainnet-beta)
    ENV_FILE="$KDIR/.env.mainnet"
    STATE="$KDIR/mainnet"
    SPONSOR_CONFIG="$KDIR/sponsor.mainnet.toml"
    if [[ "${CONFIRM_MAINNET:-}" != "yes" ]]; then
      echo "CLUSTER=mainnet-beta starts Kora nodes that pay real SOL from the" >&2
      echo "signer in kora/.env.mainnet. Re-run with CONFIRM_MAINNET=yes." >&2
      exit 1
    fi
    ;;
  *) echo "CLUSTER must be devnet or mainnet-beta, got $CLUSTER" >&2; exit 1 ;;
esac
mkdir -p "$STATE"
ENV_NAME="kora/$(basename "$ENV_FILE")"

[[ -f "$ENV_FILE" ]] || { echo "missing $ENV_FILE (see docs/KORA.md)" >&2; exit 1; }
for var in SPONSOR_API_KEY PAYMASTER_API_KEY; do
  if ! grep -qE "^$var=.+" "$ENV_FILE"; then
    sed -i "/^$var=/d" "$ENV_FILE"
    (umask 077; printf '%s=%s\n' "$var" "$(openssl rand -hex 32)" >>"$ENV_FILE")
    chmod 600 "$ENV_FILE"
    echo "generated $var in $ENV_NAME"
  fi
done
set -a; source "$ENV_FILE"; set +a
: "${KORA_SIGNER_PRIVATE_KEY:?KORA_SIGNER_PRIVATE_KEY not set in $ENV_NAME}"
: "${SPONSOR_API_KEY:?SPONSOR_API_KEY not set in $ENV_NAME}"
: "${PAYMASTER_API_KEY:?PAYMASTER_API_KEY not set in $ENV_NAME}"
if [[ "$CLUSTER" == "mainnet-beta" ]]; then
  : "${RPC_URL:?RPC_URL (a mainnet RPC) not set in $ENV_NAME}"
  : "${JUPITER_API_KEY:?JUPITER_API_KEY not set in $ENV_NAME (margin pricing)}"
  if [[ "$RPC_URL" == *devnet* || "$RPC_URL" == *testnet* ]]; then
    echo "RPC_URL in $ENV_NAME is not a mainnet RPC" >&2; exit 1
  fi
  [[ -z "${TEST_USDC_MINT:-}" ]] || { echo "TEST_USDC_MINT is devnet-only" >&2; exit 1; }
fi
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
# Outflow caps: vault rent 7_711_440 (1390 bytes), ATA rent 1_488_440
# (165 bytes; 1_513_840 for a 170-byte Token-2022 ATA), network fee <= 50_000
# (gateway cap). Plan: 1 vault + 2 ATAs + fee = 10_738_320 <= 11_500_000.
if [[ "$CLUSTER" == "mainnet-beta" ]]; then
  # One margin-priced node serves every tier (price = fee + outflow + 15%).
  PM_CONFIG="$KDIR/paymaster.mainnet.toml"
  PM_ACCOUNT_PORT=8091
  PM_BASIC_PORT=8091
else
  render_tier plan    8091 3000000 11500000 true
  render_tier account 8092 500000  4150000  true
  render_tier basic   8093 20000   60000    false
  PM_CONFIG="$KDIR/paymaster-plan.run.toml"
  PM_ACCOUNT_PORT=8092
  PM_BASIC_PORT=8093
fi

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

start_node sponsor 8090 "$SPONSOR_API_KEY" "$SPONSOR_CONFIG"

# The paymaster's USDC payment ATA(s) on the signer; a no-op once they exist.
if ! "$KORA_BIN" --config "$PM_CONFIG" --rpc-url "$RPC_URL" \
    rpc initialize-atas --signers-config "$KDIR/signers.toml" \
    >>"$LOGS/paymaster.log" 2>&1; then
  echo "warning: kora rpc initialize-atas failed (see $LOGS/paymaster.log); USDC payments fail until the payment ATA exists" >&2
fi
start_node paymaster 8091 "$PAYMASTER_API_KEY" "$PM_CONFIG"
if [[ "$CLUSTER" == "devnet" ]]; then
  start_node paymaster-account 8092 "$PAYMASTER_API_KEY" "$KDIR/paymaster-account.run.toml"
  start_node paymaster-basic 8093 "$PAYMASTER_API_KEY" "$KDIR/paymaster-basic.run.toml"
fi

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
    GATEWAY_STATE="$STATE/gateway-usage.json" \
    GATEWAY_CLAIMS_STATE="$STATE/gateway-claims.json" \
    PAYMASTER_PORT=8081 PAYMASTER_UPSTREAM=http://127.0.0.1:8091 \
    PAYMASTER_ACCOUNT_UPSTREAM="http://127.0.0.1:$PM_ACCOUNT_PORT" \
    PAYMASTER_BASIC_UPSTREAM="http://127.0.0.1:$PM_BASIC_PORT" \
    PAYMASTER_STATE="$STATE/paymaster-usage.json" \
    PAYMASTER_CREATES_STATE="$STATE/paymaster-creates.json" \
    PAYMASTER_ATAS_STATE="$STATE/paymaster-atas.json" \
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
if [[ "$CLUSTER" == "mainnet-beta" ]]; then
  SIGNER="$(curl -sf http://127.0.0.1:8081 -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getPayerSigner"}' |
    grep -oE '"signer_address":"[1-9A-HJ-NP-Za-km-z]+"' | cut -d'"' -f4 || true)"
  echo "mainnet: a mainnet app build accepts only https Kora URLs. Serve :8080"
  echo "and :8081 behind a TLS reverse proxy and build with"
  echo "  --dart-define=KORA_SPONSOR_URL=https://<host> --dart-define=KORA_PAYMASTER_URL=https://<host>"
  echo "  --dart-define=KORA_PAYMASTER_SIGNER=${SIGNER:-<signer_address from getPayerSigner>}"
fi

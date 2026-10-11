#!/usr/bin/env bash
# Start the Pyth price pusher in the background: it keeps the shard-0
# push-oracle accounts of the feeds Pyth does not sponsor (SKR/USD, ORE/USD;
# kora/pyth-price-config.yaml) fresh, so plans with an SKR fee reserve can
# pay their release fee in SKR. Without it those prices go stale and every
# payout falls back to the normal fee in its own asset.
#
# Uses @pythnetwork/price-pusher (tool/pyth_pusher; `npm ci` there first) in
# solana mode against Hermes. Pays from kora/pyth-pusher-key.json (devnet)
# or kora/mainnet/pyth-pusher-key.json (CLUSTER=mainnet-beta, which also
# needs CONFIRM_MAINNET=yes); see docs/ADMIN_DEVNET.md to create and fund it.
#
# Settings, from the environment or else from kora/.env (kora/.env.mainnet):
#   RPC_URL                    Solana RPC (devnet default: api.devnet.solana.com)
#   PYTH_HERMES_URL            Hermes endpoint (default https://hermes.pyth.network)
#   PYTH_HERMES_ACCESS_TOKEN   Hermes API key; the public endpoint requires one
#   PYTH_PUSHER_CU_PRICE       priority fee, micro-lamports per CU (devnet 0,
#                              mainnet 50000)
# Logs to kora/logs/pyth-pusher.log; scripts/pyth_pusher_stop.sh stops it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KDIR="$ROOT/kora"
LOGS="$KDIR/logs"
PUSHER_DIR="$ROOT/tool/pyth_pusher"
PIDF="$KDIR/pyth-pusher.pid"
PUSH_ORACLE="pythWSnswVUd12oZpeFP8e9CVaEqJg25g1Vtc2biRsT"
mkdir -p "$LOGS"

CLUSTER="${CLUSTER:-devnet}"
case "$CLUSTER" in
  devnet)
    ENV_FILE="$KDIR/.env"
    KEY_FILE="$KDIR/pyth-pusher-key.json"
    GENESIS="EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG"
    DEFAULT_RPC="https://api.devnet.solana.com"
    DEFAULT_CU_PRICE=0
    ;;
  mainnet-beta)
    ENV_FILE="$KDIR/.env.mainnet"
    KEY_FILE="$KDIR/mainnet/pyth-pusher-key.json"
    GENESIS="5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d"
    DEFAULT_RPC=""
    DEFAULT_CU_PRICE=50000
    if [[ "${CONFIRM_MAINNET:-}" != "yes" ]]; then
      echo "CLUSTER=mainnet-beta pushes prices with real SOL from" >&2
      echo "$KEY_FILE. Re-run with CONFIRM_MAINNET=yes." >&2
      exit 1
    fi
    ;;
  *) echo "CLUSTER must be devnet or mainnet-beta, got $CLUSTER" >&2; exit 1 ;;
esac

if [[ -f "$PIDF" ]] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  echo "pyth-pusher already running (pid $(cat "$PIDF"))"
  exit 0
fi
[[ -f "$KEY_FILE" ]] || {
  echo "missing $KEY_FILE: create and fund it (docs/ADMIN_DEVNET.md)" >&2
  exit 1
}
BIN="$PUSHER_DIR/node_modules/@pythnetwork/price-pusher/dist/index.cjs"
[[ -f "$BIN" ]] || {
  echo "price-pusher not installed: (cd tool/pyth_pusher && npm ci)" >&2
  exit 1
}
command -v node >/dev/null || { echo "node not found (Node 24+)" >&2; exit 1; }

# One variable from the env file, without sourcing it (it also holds the
# Kora signer key, which the pusher must not see).
env_value() {
  [[ -f "$ENV_FILE" ]] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1 | sed -E "s/^['\"](.*)['\"]$/\1/"
}
RPC_URL="${RPC_URL:-$(env_value RPC_URL)}"
RPC_URL="${RPC_URL:-$DEFAULT_RPC}"
[[ -n "$RPC_URL" ]] || { echo "RPC_URL is required on $CLUSTER" >&2; exit 1; }
HERMES_URL="${PYTH_HERMES_URL:-$(env_value PYTH_HERMES_URL)}"
HERMES_URL="${HERMES_URL:-https://hermes.pyth.network}"
HERMES_TOKEN="${PYTH_HERMES_ACCESS_TOKEN:-$(env_value PYTH_HERMES_ACCESS_TOKEN)}"
CU_PRICE="${PYTH_PUSHER_CU_PRICE:-$(env_value PYTH_PUSHER_CU_PRICE)}"
CU_PRICE="${CU_PRICE:-$DEFAULT_CU_PRICE}"
[[ "$CU_PRICE" =~ ^[0-9]+$ ]] || { echo "PYTH_PUSHER_CU_PRICE must be an integer" >&2; exit 1; }
if [[ -n "$HERMES_TOKEN" && ! "$HERMES_TOKEN" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
  echo "PYTH_HERMES_ACCESS_TOKEN has unexpected characters" >&2; exit 1
fi
if [[ -z "$HERMES_TOKEN" && "$HERMES_URL" == "https://hermes.pyth.network" ]]; then
  echo "hermes.pyth.network needs an API key: set PYTH_HERMES_ACCESS_TOKEN in" >&2
  echo "kora/$(basename "$ENV_FILE") (or PYTH_HERMES_URL to another Hermes)." >&2
  exit 1
fi

got="$(curl -sf --max-time 15 "$RPC_URL" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"getGenesisHash"}' |
  grep -oE '"result":"[1-9A-HJ-NP-Za-km-z]+"' | cut -d'"' -f4 || true)"
if [[ "$got" != "$GENESIS" ]]; then
  echo "RPC_URL is not a $CLUSTER RPC (genesis ${got:-unreachable})" >&2
  exit 1
fi

# The Hermes key goes in a private config file, not on the command line.
RUN_CONFIG="$KDIR/pyth-pusher.run.json"
(
  umask 077
  if [[ -n "$HERMES_TOKEN" ]]; then
    printf '{"enable-metrics": false, "hermes-access-token": "%s"}\n' \
      "$HERMES_TOKEN" >"$RUN_CONFIG"
  else
    printf '{"enable-metrics": false}\n' >"$RUN_CONFIG"
  fi
)

# Own process group, so pyth_pusher_stop.sh stops it with one signal.
setsid nohup node "$BIN" solana \
  --config "$RUN_CONFIG" \
  --endpoint "$RPC_URL" \
  --keypair-file "$KEY_FILE" \
  --shard-id 0 \
  --pyth-contract-address "$PUSH_ORACLE" \
  --price-service-endpoint "$HERMES_URL" \
  --price-config-file "$KDIR/pyth-price-config.yaml" \
  --compute-unit-price-micro-lamports "$CU_PRICE" \
  --pushing-frequency 30 \
  --polling-frequency 5 \
  </dev/null >>"$LOGS/pyth-pusher.log" 2>&1 &
echo $! >"$PIDF"

# The pusher has no health endpoint: give it time to load and connect.
for _ in $(seq 1 20); do
  kill -0 "$(cat "$PIDF")" 2>/dev/null || break
  sleep 0.5
done
if ! kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  rm -f "$PIDF"
  echo "pyth-pusher failed to start; last log lines:" >&2
  tail -n 20 "$LOGS/pyth-pusher.log" >&2
  exit 1
fi
# Host only: RPC URLs often carry an API key in the query.
host="${RPC_URL#*://}"
echo "pyth-pusher up on $CLUSTER via ${host%%[/?]*} (pid $(cat "$PIDF")), log $LOGS/pyth-pusher.log"

#!/usr/bin/env bash
# One-time setup after deploying the program: initializes the Config with the
# treasury and payout fees. Run it yourself; it signs with the keypair you
# pass (must be the program's upgrade authority).
#
#   KEYPAIR=/path/to/upgrade-authority.json scripts/devnet_setup.sh
#   FEE_PUBLIC=200 FEE_PRIVATE=500 TREASURY=<addr> URL=<rpc> are optional.
set -euo pipefail

: "${KEYPAIR:?set KEYPAIR to your upgrade-authority keypair path}"
URL="${URL:-https://api.devnet.solana.com}"
cd "$(dirname "$0")/.."

ADMIN=$(solana-keygen pubkey "$KEYPAIR")
TREASURY="${TREASURY:-$ADMIN}"

dart run tool/init_config.dart --keypair "$KEYPAIR" --treasury "$TREASURY" \
  --fee-public "${FEE_PUBLIC:-200}" --fee-private "${FEE_PRIVATE:-500}" --rpc "$URL"

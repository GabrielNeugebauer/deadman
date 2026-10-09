#!/usr/bin/env bash
# One-time setup after deploying the program: initializes the Config with the
# treasury and the SKR mint. The program sets the default fees (2% per
# release, 1.5% for payouts in SKR, 10% of that burned); change them with
# tool/set_config.dart (docs/ADMIN_DEVNET.md). Run it yourself; it signs with
# the keypair you pass (must be the program's upgrade authority).
#
#   KEYPAIR=/path/to/upgrade-authority.json scripts/devnet_setup.sh
#   TREASURY=<system-owned wallet> SKR_MINT=<mint|none> URL=<rpc> are
#   optional (SKR_MINT defaults to the devnet test SKR).
set -euo pipefail

: "${KEYPAIR:?set KEYPAIR to your upgrade-authority keypair path}"
URL="${URL:-https://api.devnet.solana.com}"
cd "$(dirname "$0")/.."

ADMIN=$(solana-keygen pubkey "$KEYPAIR")
TREASURY="${TREASURY:-$ADMIN}"

dart run tool/init_config.dart --keypair "$KEYPAIR" --treasury "$TREASURY" \
  --skr-mint "${SKR_MINT:-4JX81qZWhPPT38Tn4ZswaS2DyH3PffdrFqbYgsoZCuHc}" \
  --rpc "$URL"

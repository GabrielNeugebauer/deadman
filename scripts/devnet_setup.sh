#!/usr/bin/env bash
# One-time devnet setup after deploying the program: mock SKR mint, treasury
# token account, and the program Config. Run it yourself; it signs with the
# keypair you pass (must be the program's upgrade authority).
#
#   KEYPAIR=/path/to/upgrade-authority.json scripts/devnet_setup.sh
set -euo pipefail

: "${KEYPAIR:?set KEYPAIR to your upgrade-authority keypair path}"
URL="${URL:-https://api.devnet.solana.com}"
cd "$(dirname "$0")/.."

ADMIN=$(solana-keygen pubkey "$KEYPAIR")
TREASURY="${TREASURY:-$ADMIN}"

if [ -z "${SKR_MINT:-}" ]; then
  SKR_MINT=$(spl-token create-token --decimals 6 --url "$URL" --fee-payer "$KEYPAIR" \
    --mint-authority "$ADMIN" | awk '/^Address:/{print $2}')
  echo "Mock SKR mint: $SKR_MINT"
fi

spl-token create-account "$SKR_MINT" --owner "$TREASURY" --url "$URL" \
  --fee-payer "$KEYPAIR" 2>/dev/null || true
spl-token mint "$SKR_MINT" 1000000 --url "$URL" --fee-payer "$KEYPAIR" \
  --mint-authority "$KEYPAIR" --recipient-owner "$ADMIN" 2>/dev/null || true

dart run tool/init_config.dart --keypair "$KEYPAIR" --treasury "$TREASURY" \
  --skr-mint "$SKR_MINT" --rpc "$URL"

echo
echo "Build the app with:"
echo "  flutter build apk --release --dart-define=SKR_MINT=$SKR_MINT"
echo "Send test SKR to a tester:"
echo "  spl-token transfer $SKR_MINT 100 <WALLET> --fund-recipient --allow-unfunded-recipient --url $URL --fee-payer \$KEYPAIR"

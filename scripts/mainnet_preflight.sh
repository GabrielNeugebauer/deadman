#!/usr/bin/env bash
# Read-only checks before deploying the Deadman program to mainnet
# (docs/MAINNET.md). Sends nothing and signs nothing: it only builds/tests
# locally and reads from the RPC. Key files are read for their public key
# only (`solana address`, `solana-keygen pubkey`).
#
#   RPC_URL=<mainnet rpc> scripts/mainnet_preflight.sh [--skip-tests] [--verifiable]
#
#   --skip-tests   skip cargo fmt --check, clippy and cargo test
#   --verifiable   run `anchor build --verifiable` (Docker, several minutes)
#   CU_PRICE       priority fee assumed for the deploy estimate
#                  (micro-lamports per CU, default 100000)
#
# Exit code 1 if any check FAILs. WARNs need a human decision.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ONCHAIN="$ROOT/onchain"
PROGRAM_ID="ACHVLMoLDM3YPpGbNST4cZW4Tf2jx6nzJGuusyLJHofL"
MAINNET_GENESIS="5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d"
RPC="${RPC_URL:-https://api.mainnet-beta.solana.com}"
CU_PRICE="${CU_PRICE:-100000}"
SO="$ONCHAIN/target/deploy/deadman.so"
VSO="$ONCHAIN/target/verifiable/deadman.so"
IDL="$ONCHAIN/target/idl/deadman.json"
PROGRAM_KEYPAIR="$ONCHAIN/target/deploy/deadman-keypair.json"
SRC="$ONCHAIN/programs/deadman"
RPC_HOST="$(sed -E 's#^[a-z]+://([^/?]+).*#\1#' <<<"$RPC")"

SKIP_TESTS=0
VERIFIABLE=0
for arg in "$@"; do
  case "$arg" in
    --skip-tests) SKIP_TESTS=1 ;;
    --verifiable) VERIFIABLE=1 ;;
    *) echo "unknown option $arg" >&2; exit 64 ;;
  esac
done

PASS=0 WARN=0 FAIL=0
pass() { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$*"; }
warn() { WARN=$((WARN + 1)); printf '  [WARN] %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$*"; }
section() { printf '\n== %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
sol() { awk -v l="$1" 'BEGIN { printf "%.6f", l / 1e9 }'; }
# Rent-exempt minimum in lamports for N bytes, from the cluster.
rent() { solana rent "$1" --lamports --url "$RPC" 2>/dev/null | grep -oE '[0-9]+' | head -1; }

echo "Deadman mainnet preflight ($(date -u +%FT%TZ)), RPC host $RPC_HOST"
echo "Read-only: nothing is signed or sent."

section "Toolchain"
if have solana; then pass "$(solana --version)"; else fail "solana CLI not found"; fi
if have anchor; then
  v="$(anchor --version 2>/dev/null)"
  [[ "$v" == *"1.1.2"* ]] && pass "$v" || fail "$v (expected anchor-cli 1.1.2)"
else
  fail "anchor not found"
fi
want_rust="$(sed -nE 's/^channel *= *"([^"]+)"/\1/p' "$ONCHAIN/rust-toolchain.toml")"
got_rust="$(cd "$ONCHAIN" && rustc --version 2>/dev/null)"
[[ "$got_rust" == *"$want_rust"* ]] && pass "$got_rust (pinned $want_rust)" \
  || warn "rustc '$got_rust', onchain/rust-toolchain.toml pins $want_rust"
if have docker && docker info >/dev/null 2>&1; then
  pass "docker $(docker info --format '{{.ServerVersion}}') running (verifiable build)"
else
  warn "docker not running: needed for anchor build --verifiable"
fi
have solana-verify && pass "$(solana-verify --version 2>/dev/null | head -1)" \
  || warn "solana-verify not installed (optional; cargo install solana-verify)"
have jq || fail "jq not found"

section "Program id"
declared="$(grep -oP 'declare_id!\("\K[1-9A-HJ-NP-Za-km-z]+' "$SRC/src/lib.rs")"
[[ "$declared" == "$PROGRAM_ID" ]] && pass "declare_id! = $PROGRAM_ID" \
  || fail "declare_id! is $declared, expected $PROGRAM_ID"
if [[ -f "$PROGRAM_KEYPAIR" ]]; then
  kp="$(solana-keygen pubkey "$PROGRAM_KEYPAIR" 2>/dev/null)"
  [[ "$kp" == "$PROGRAM_ID" ]] && pass "target/deploy/deadman-keypair.json -> $kp" \
    || fail "program keypair is $kp, not $PROGRAM_ID"
else
  fail "missing $PROGRAM_KEYPAIR (needed to deploy at $PROGRAM_ID)"
fi
# The tools (init_config, set_config, keeper, gateway) take it from here.
grep -q "$PROGRAM_ID" "$ROOT/lib/core/config.dart" \
  && pass "lib/core/config.dart uses $PROGRAM_ID" \
  || fail "lib/core/config.dart does not reference $PROGRAM_ID"

section "Build artifacts"
if [[ -f "$SO" ]]; then
  SO_BYTES="$(stat -c %s "$SO")"
  pass "deadman.so $SO_BYTES bytes, sha256 $(sha256sum "$SO" | cut -c1-64)"
  newer="$(find "$SRC/src" "$SRC/Cargo.toml" "$ONCHAIN/Cargo.lock" -newer "$SO" -type f | sed "s#$ROOT/##")"
  [[ -z "$newer" ]] && pass "deadman.so is newer than every program source" \
    || fail "sources changed after the last build (run anchor build): $(tr '\n' ' ' <<<"$newer")"
else
  SO_BYTES=0
  fail "missing $SO (cd onchain && anchor build)"
fi
if [[ -f "$IDL" ]]; then
  idl_addr="$(jq -r .address "$IDL")"
  [[ "$idl_addr" == "$PROGRAM_ID" ]] && pass "IDL address $idl_addr" \
    || fail "IDL address $idl_addr"
  idl_ix="$(jq -r '.instructions[].name' "$IDL" | sort | tr '\n' ' ')"
  src_ix="$(grep -oP '^\s*pub fn \K[a-z_0-9]+' "$SRC/src/lib.rs" | sort | tr '\n' ' ')"
  [[ "$idl_ix" == "$src_ix" ]] && pass "IDL has the $(wc -w <<<"$idl_ix") instructions of lib.rs" \
    || fail "IDL instructions differ from lib.rs: IDL [$idl_ix] src [$src_ix]"
  # anchor build writes the .so, then the IDL, within a few minutes.
  gap=$(( $(stat -c %Y "$IDL") - $(stat -c %Y "$SO" 2>/dev/null || echo 0) ))
  [[ $gap -ge 0 && $gap -lt 600 ]] && pass "IDL from the same anchor build as deadman.so (${gap}s apart)" \
    || fail "IDL and deadman.so come from different builds (${gap}s apart); rerun anchor build"
else
  fail "missing $IDL"
fi
dirty="$(cd "$ROOT" && git status --porcelain -- onchain/programs onchain/Cargo.toml onchain/Cargo.lock 2>/dev/null)"
[[ -z "$dirty" ]] && pass "program sources committed ($(cd "$ROOT" && git rev-parse --short HEAD))" \
  || warn "uncommitted program changes; a verifiable build must come from a pushed commit: $(tr '\n' ' ' <<<"$dirty")"

section "Format, lint, tests"
if [[ $SKIP_TESTS == 1 ]]; then
  warn "skipped (--skip-tests)"
else
  (cd "$ONCHAIN" && cargo fmt --all -- --check >/dev/null 2>&1) && pass "cargo fmt --check" \
    || fail "cargo fmt --check (run cargo fmt --all)"
  if (cd "$ONCHAIN" && cargo clippy --quiet -- -W clippy::all -D warnings >/tmp/deadman-clippy.$$ 2>&1); then
    pass "cargo clippy -W clippy::all (no warnings)"
  else
    fail "clippy: $(grep -m1 -E '^(warning|error)' /tmp/deadman-clippy.$$)"
  fi
  rm -f /tmp/deadman-clippy.$$
  out="$(cd "$ONCHAIN" && cargo test 2>&1)"
  results="$(grep -E '^test result:' <<<"$out" | sed -E 's/; finished.*//' | tr '\n' ' ')"
  if grep -qE '^test result: FAILED|error(\[|:)' <<<"$out"; then
    fail "cargo test: $results$(grep -m3 -E '^test .* FAILED|^error' <<<"$out" | tr '\n' ' ')"
  else
    pass "cargo test: $results"
  fi
fi

section "Verifiable build"
if [[ $VERIFIABLE == 1 ]]; then
  (cd "$ONCHAIN" && anchor build --verifiable) >/tmp/deadman-verifiable.$$ 2>&1 \
    && pass "anchor build --verifiable" \
    || fail "anchor build --verifiable: $(tail -3 /tmp/deadman-verifiable.$$ | tr '\n' ' ')"
  rm -f /tmp/deadman-verifiable.$$
fi
if [[ -f "$VSO" ]]; then
  pass "verifiable deadman.so sha256 $(sha256sum "$VSO" | cut -c1-64) (publish this)"
  have solana-verify && pass "solana-verify executable hash $(solana-verify get-executable-hash "$VSO" 2>/dev/null)"
  newer="$(find "$SRC/src" "$SRC/Cargo.toml" "$ONCHAIN/Cargo.lock" -newer "$VSO" -type f | head -3)"
  [[ -z "$newer" ]] || fail "sources changed after the verifiable build"
  [[ -f "$SO" ]] && ! cmp -s "$SO" "$VSO" \
    && warn "target/deploy/deadman.so differs from the verifiable build; deploy target/verifiable/deadman.so"
else
  warn "no target/verifiable/deadman.so yet (rerun with --verifiable, or: cd onchain && anchor build --verifiable)"
fi

section "Mainnet RPC ($RPC_HOST)"
genesis="$(solana genesis-hash --url "$RPC" 2>/dev/null)"
if [[ "$genesis" == "$MAINNET_GENESIS" ]]; then
  pass "genesis $genesis (mainnet-beta), $(solana cluster-version --url "$RPC" 2>/dev/null | head -1)"
else
  fail "RPC unreachable or not mainnet (genesis '${genesis:-none}')"
fi

DEPLOYED=0
show="$(solana program show "$PROGRAM_ID" --url "$RPC" 2>&1)"
if grep -q "^Program Id" <<<"$show"; then
  DEPLOYED=1
  auth="$(awk -F': *' '/^Authority/ {print $2}' <<<"$show")"
  len="$(awk -F': *' '/^Data Length/ {print $2}' <<<"$show")"
  warn "program already on mainnet (upgrade, not first deploy): authority $auth, data length $len"
  tmp="$(mktemp)"
  if solana program dump "$PROGRAM_ID" "$tmp" --url "$RPC" >/dev/null 2>&1; then
    echo "         on-chain sha256 (padded to data length) $(sha256sum "$tmp" | cut -c1-64)"
    have solana-verify && echo "         on-chain program hash $(solana-verify get-program-hash -u "$RPC" "$PROGRAM_ID" 2>/dev/null)"
  fi
  rm -f "$tmp"
else
  pass "program $PROGRAM_ID not on mainnet yet (first deploy)"
fi

CONFIG_PDA="$(solana find-program-derived-address "$PROGRAM_ID" string:config 2>/dev/null | head -1)"
if solana account "$CONFIG_PDA" --url "$RPC" >/dev/null 2>&1; then
  warn "config PDA $CONFIG_PDA exists: init_config already ran (check treasury/fees)"
else
  pass "config PDA $CONFIG_PDA absent (init_config after deploy)"
fi

section "Deploy wallet and cost estimate"
if [[ "$SO_BYTES" -gt 0 && "$genesis" == "$MAINNET_GENESIS" ]]; then
  MAX_LEN=$((SO_BYTES * 2))
  programdata=$(rent $((MAX_LEN + 45)))       # ProgramData header 45 bytes
  buffer=$(rent $((SO_BYTES + 37)))           # Buffer header 37 bytes; refunded
  program=$(rent 36)
  config=$(rent 209)                          # 8 + Config::INIT_SPACE
  idl=$(rent "$(stat -c %s "$IDL")")          # upper bound: uncompressed IDL
  writes=$(( (SO_BYTES + 999) / 1000 + 4 ))
  fees=$(( writes * (5000 + CU_PRICE * 200000 / 1000000) ))
  margin=50000000
  need=$((programdata + buffer + program + config + idl + fees + margin))
  printf '         --max-len %s (2x the .so)\n' "$MAX_LEN"
  printf '         program data rent  %s SOL (locked while the program exists)\n' "$(sol "$programdata")"
  printf '         buffer rent        %s SOL (only during the deploy, refunded)\n' "$(sol "$buffer")"
  printf '         program account    %s SOL\n' "$(sol "$program")"
  printf '         config PDA         %s SOL\n' "$(sol "$config")"
  printf '         IDL (upper bound)  %s SOL\n' "$(sol "$idl")"
  printf '         %s txs at <= %s lamports  %s SOL (CU_PRICE=%s)\n' "$writes" $((5000 + CU_PRICE * 200000 / 1000000)) "$(sol "$fees")" "$CU_PRICE"
  printf '         margin             %s SOL\n' "$(sol "$margin")"
  printf '         needed at deploy   %s SOL (about %s SOL after the buffer is refunded)\n' "$(sol "$need")" "$(sol $((need - buffer)))"
  if wallet="$(solana address 2>/dev/null)"; then
    bal="$(solana balance "$wallet" --lamports --url "$RPC" 2>/dev/null | awk '{print $1}')"
    if [[ -n "$bal" && "$bal" -ge "$need" ]]; then
      pass "deploy wallet $wallet holds $(sol "$bal") SOL"
    else
      fail "deploy wallet $wallet holds $(sol "${bal:-0}") SOL; needs $(sol "$need")"
    fi
  else
    fail "no default keypair (solana config get keypair)"
  fi
else
  warn "cost estimate skipped (needs deadman.so and a mainnet RPC)"
fi

printf '\n== Result: %d pass, %d warn, %d fail\n' "$PASS" "$WARN" "$FAIL"
[[ $FAIL -eq 0 ]] && echo "Ready for the deploy steps in docs/MAINNET.md once every WARN is understood." \
  || echo "Fix every FAIL before deploying."
exit $(( FAIL > 0 ))

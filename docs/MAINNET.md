# Mainnet runbook

This is the step-by-step for putting Deadman on Solana mainnet and testing it there with real funds. Nothing in it has run yet; every command that spends SOL is marked **(spends)**. Read [Risks](#risks) first.

Yes, the program must be on mainnet before a mainnet test. The private rails (Zcash via 1Click, Cloak) exist only on mainnet, and a mainnet app build talks to the program at the same address, `ACHVLMoLDM3YPpGbNST4cZW4Tf2jx6nzJGuusyLJHofL`. The program keypair in `onchain/target/deploy/deadman-keypair.json` deploys to that address on any cluster.

| #   | Step                                                          | Who signs         | Spends                 |
| --- | ------------------------------------------------------------- | ----------------- | ---------------------- |
| 0   | [Gate: fixes merged, code frozen](#0-gate)                    | nobody            | nothing                |
| 1   | [Preflight](#1-preflight)                                     | nobody            | nothing                |
| 2   | [Verifiable build](#2-verifiable-build)                       | nobody            | nothing                |
| 3   | [Deploy](#3-deploy)                                           | deploy wallet     | ~7.6 SOL, ~5.1 stays   |
| 4   | [Initialize Config](#4-initialize-config)                     | upgrade authority | ~0.001 SOL             |
| 5   | [Publish the IDL](#5-publish-the-idl)                         | upgrade authority | ≤ 0.26 SOL             |
| 6   | [Upgrade authority to Squads](#6-upgrade-authority-to-squads) | deploy wallet     | fee only               |
| 7   | [Kora sponsor and paymaster](#7-kora-on-mainnet)              | Kora fee payer    | float, 0.5 SOL         |
| 8   | [Keeper](#8-keeper-on-mainnet)                                | keeper key        | float, 0.1 SOL         |
| 9   | [Mainnet APK](#9-mainnet-apk)                                 | nobody            | nothing                |
| 10  | [End-to-end test with real funds](#10-end-to-end-test)        | throwaway keys    | ~0.015 SOL + 0.02 USDC |

Set these once per shell. Use a paid RPC (Helius): the public endpoint rate-limits deploys and `getProgramAccounts`, and answers 403 to browsers.

```bash
cd ~/Documentos/Deadman/deadman
export RPC_URL='https://mainnet.helius-rpc.com/?api-key=<key>'
export PROGRAM_ID=ACHVLMoLDM3YPpGbNST4cZW4Tf2jx6nzJGuusyLJHofL
export DEPLOYER=~/.config/solana/mainnet-deployer.json   # see step 3
```

## Prerequisites

- Solana CLI 2.x or newer (tested shape: `solana-cli 3.1.10`), `solana-keygen`.
- Anchor CLI **1.1.2** and Rust **1.89.0** (pinned in `onchain/rust-toolchain.toml`).
- Docker, running, for `anchor build --verifiable`.
- Optional: `solana-verify` (`cargo install solana-verify`) to publish the build to the OtterSec verification registry.
- Dart/Flutter as in the README, Node 20+ and `npx playwright install chromium-headless-shell` (for the Cloak leg of the end-to-end test).
- A [Squads](https://app.squads.so) multisig on mainnet (step 6).
- A Helius (or similar) mainnet API key; a Jupiter API key for the Kora paymaster's margin pricing.

## Cost estimate

Measured on 2026-10-04 with `scripts/mainnet_preflight.sh` (rent from mainnet `solana rent`, read-only) for the `deadman.so` built that day, **475 272 bytes**. Mainnet rent is now 5 080 lamports per byte plus the 128-byte account overhead (a 165-byte token account costs 0.00148844 SOL, not the older 0.00203928). Rerun the preflight after the final build: the numbers scale with the `.so` size.

| Item                                            | SOL        | Notes                                                           |
| ----------------------------------------------- | ---------- | --------------------------------------------------------------- |
| Program data, `--max-len 950544` (2x the `.so`) | 4.829642   | locked while the program exists; 2.42 SOL without the headroom  |
| Deploy buffer (475 309 bytes)                   | 2.415220   | needed during the deploy, refunded when it completes            |
| Program account (36 bytes)                      | 0.000833   |                                                                 |
| Config PDA (77 bytes)                           | 0.001041   | step 4                                                          |
| IDL metadata account                            | ≤ 0.255057 | upper bound (the uncompressed 47 KB IDL); step 5 is optional    |
| ~480 write transactions at ≤ 25 000 lamports    | ≤ 0.012    | 5 000 base + priority fee at `--with-compute-unit-price 100000` |
| Margin                                          | 0.05       |                                                                 |
| **Deploy wallet must hold**                     | **7.56**   | about **5.15 SOL stays locked** after the buffer comes back     |

Running costs: the Kora fee payer float (0.5 SOL suggested, step 7), the keeper float (0.1 SOL, step 8), and the end-to-end test (about 0.12 SOL and 1 USDC funded, about 0.015 SOL and 0.02 USDC actually spent, step 10). Closing the program later (`solana program close`) returns the program-data rent, but the address can then never be reused.

## 0. Gate

Do not deploy until all of these hold:

- The Medium findings of [security-review-2026-10-04.md](security-review-2026-10-04.md) are fixed and reviewed: M-1 (Kora-funded ATAs), M-2 (quota taken before Kora succeeds), M-3 (client pins the paymaster signer and caps the fee: `KORA_PAYMASTER_SIGNER`, `KORA_MAX_FEE`).
- The program-side items are in the build you deploy: rent stored at creation (`rent_paid`, L-2), the final account layout with `_reserved` padding (`Vault::SPACE` = 1390), `recover_legacy_vault` (L-1), and the per-rail stipend (`CLOAK_GAS_STIPEND` 0.012 SOL, so a Cloak USDC tier no longer needs a manual SOL top-up; see [private-rails-test-2026-10-04.md](research/private-rails-test-2026-10-04.md)).
- `cargo test`, `flutter test`, `cargo clippy -- -W clippy::all` and `dart analyze` are clean.
- Everything under `onchain/` is committed and pushed to the public repository (a verifiable build is checked against a commit).
- You accept the [risks](#risks), above all that no one outside the team has audited the program.

## 1. Preflight

Read-only. It builds nothing new unless asked, signs nothing and sends nothing.

```bash
RPC_URL=$RPC_URL scripts/mainnet_preflight.sh              # full: fmt, clippy, cargo test
RPC_URL=$RPC_URL scripts/mainnet_preflight.sh --verifiable # also runs anchor build --verifiable
```

It checks the toolchain, that the declared id, the program keypair, the IDL, `lib/core/config.dart` and `tool/init_config.dart` all agree on the program id, that `deadman.so` and the IDL come from the same build and are newer than every source, that the program sources are committed, fmt/clippy/tests, the verifiable hash, that the RPC is mainnet (genesis `5eykt4Us…`), whether the program and the Config PDA (`BqTe2haaD7dPfc4dmYQFaGrczbMhrXiuddc2knjvoCgr`) already exist, and the deploy wallet's balance (`solana address`, public key only) against the cost estimate. It exits 1 on any FAIL. On 2026-10-04 the only FAIL was the unfunded wallet.

## 2. Verifiable build

```bash
cd onchain
anchor build --verifiable                  # Docker; writes target/verifiable/deadman.so
sha256sum target/verifiable/deadman.so     # publish this hash (README, release notes)
solana-verify get-executable-hash target/verifiable/deadman.so   # optional, same tool the registry uses
cd ..
```

Deploy `target/verifiable/deadman.so`, not `target/deploy/deadman.so`. Anyone can then rebuild the tagged commit and compare. After the deploy:

```bash
solana-verify get-program-hash -u "$RPC_URL" $PROGRAM_ID   # must equal the executable hash above
```

To list it on the OtterSec registry, run `solana-verify verify-from-repo --remote -u "$RPC_URL" --program-id $PROGRAM_ID https://github.com/<org>/deadman --commit-hash <commit> --library-name deadman --mount-path onchain` **(spends: a small PDA)**. Once the upgrade authority is a multisig (step 6), create the PDA with `solana-verify export-pda-tx` and approve it in Squads instead.

## 3. Deploy

Use a dedicated deploy key that holds nothing else, or a Ledger (`usb://ledger`). Generate it offline and never paste it anywhere:

```bash
solana-keygen new -o "$DEPLOYER"                 # write the seed phrase down; it is the upgrade authority until step 6
solana address -k "$DEPLOYER"                    # fund this address with ~7.6 SOL
solana balance -k "$DEPLOYER" --url "$RPC_URL"
```

**(spends)** Deploy at the fixed address with 2x headroom, writes through the RPC and a priority fee:

```bash
cd onchain
solana program deploy target/verifiable/deadman.so \
  --program-id target/deploy/deadman-keypair.json \
  --keypair "$DEPLOYER" --upgrade-authority "$DEPLOYER" \
  --max-len $(( $(stat -c %s target/verifiable/deadman.so) * 2 )) \
  --use-rpc --with-compute-unit-price 100000 --max-sign-attempts 20 \
  --url "$RPC_URL"
solana program show $PROGRAM_ID --url "$RPC_URL"   # Authority = deploy key, Data Length = max-len
cd ..
```

If the deploy stops halfway, the CLI prints a 12-word phrase for the intermediate buffer. Resume with `solana-keygen recover -o buffer.json` from that phrase and the same command plus `--buffer buffer.json`, or reclaim the rent with `solana program show --buffers -k "$DEPLOYER" --url "$RPC_URL"` and `solana program close <BUFFER> -k "$DEPLOYER" --url "$RPC_URL"`.

## 4. Initialize Config

`init_config` must be signed by the program's **current upgrade authority**, and that signer becomes `Config.admin` for good: there is no instruction to rotate the admin. The admin can later change the treasury and both fees (`set_config` through `tool/set_config.dart`, capped at 5%). So choose who the admin is now:

- **A, simple:** run it now with the deploy key, before step 6. The deploy key then stays the fee admin; keep it offline after the deploy.
- **B, preferred:** do step 6 first, then run `init_config` as a Squads proposal (Squads "Transaction builder", or build the same instruction as `tool/init_config.dart` with the Squads vault as admin). The multisig is then both upgrade authority and fee admin.

Option A, with the treasury as a wallet you control (a Squads vault is fine as treasury in either option) and 2% / 3% fees **(spends ~0.001 SOL)**:

```bash
dart run tool/init_config.dart --keypair "$DEPLOYER" \
  --treasury <TREASURY_ADDRESS> --fee-public 200 --fee-private 300 --rpc "$RPC_URL"
solana account BqTe2haaD7dPfc4dmYQFaGrczbMhrXiuddc2knjvoCgr --url "$RPC_URL"   # 77 bytes, owner = program
```

The treasury receives protocol fees in SOL and in each token paid out, so its token accounts get created on the first token payout (the executor pays that rent).

## 5. Publish the IDL

Optional, for explorers and integrators. Anchor 1.1.2 writes it to a program-metadata account, signed by the upgrade authority (so do it before step 6, or through Squads) **(spends ≤ 0.26 SOL)**:

```bash
cd onchain
anchor idl init --filepath target/idl/deadman.json $PROGRAM_ID \
  --provider.cluster "$RPC_URL" --provider.wallet "$DEPLOYER" --priority-fee 100000
anchor idl fetch $PROGRAM_ID --provider.cluster "$RPC_URL" | jq .address
cd ..
```

After a program upgrade, use `anchor idl upgrade` with the same flags.

## 6. Upgrade authority to Squads

1. In the Squads app, create a multisig (for example 2-of-3, members on separate devices, at least one hardware wallet) and copy its **vault** address (index 0), not the multisig account address.
2. **(spends a fee)** Hand over the upgrade authority:

   ```bash
   solana program set-upgrade-authority $PROGRAM_ID \
     --new-upgrade-authority <SQUADS_VAULT> --skip-new-upgrade-authority-signer-check \
     -k "$DEPLOYER" --url "$RPC_URL"
   solana program show $PROGRAM_ID --url "$RPC_URL"   # Authority = <SQUADS_VAULT>
   ```

   `--skip-new-upgrade-authority-signer-check` is needed because the vault is a PDA and cannot sign here. Check the address character by character first: a typo locks the program forever.

3. In Squads, add the program under Developers → Programs so upgrades can be proposed there.

Upgrades from then on: `solana program write-buffer target/verifiable/deadman.so --use-rpc --with-compute-unit-price 100000 -k <any payer> --url "$RPC_URL"`, then `solana program set-buffer-authority <BUFFER> --new-buffer-authority <SQUADS_VAULT> ...`, then propose and approve the upgrade in Squads. Solana CLI 2.x and later also extends program data automatically when a new binary is larger (`--no-auto-extend` turns that off), so the 2x headroom is a convenience, not a hard limit.

## 7. Kora on mainnet

The mainnet configs come from the paymaster work: `kora/sponsor.mainnet.toml` (free pulses and lockdowns for guard keys) and `kora/paymaster.mainnet.toml` (one node with margin pricing: network fee plus the fee payer's outflow, at the Jupiter SOL/USDC price, plus 15%; it replaces the three devnet price tiers). See [KORA.md](KORA.md) for the gateway policy.

1. Make a **separate** mainnet fee-payer key (never reuse the devnet one), ideally behind a remote signer. Create `kora/.env.mainnet` (gitignored, mode 600) with `KORA_SIGNER_PRIVATE_KEY`, `RPC_URL` (mainnet) and `JUPITER_API_KEY`. The start script generates `SPONSOR_API_KEY` and `PAYMASTER_API_KEY`.
2. Fund the fee payer **(spends)**. What it pays out:
   - a sponsored pulse or lockdown: the 5 000-lamport network fee (1 000 check-ins ≈ 0.005 SOL; the sponsor caps each guard at 1 000 for life);
   - a paymaster-funded plan: vault rent 0.00771144 SOL (1390 bytes), returned to Kora when the plan closes, plus up to 2 token accounts at 0.00148844 SOL each, which are not returned but are billed in the USDC price;
   - its own USDC payment account, once (`initialize-atas`, 0.00148844 SOL).

   Start with **0.5 SOL** (about 45 Kora-funded plans in flight). Payments accumulate as USDC in the fee payer's USDC account; swap some back to SOL when the `fee_payer_balance` metric drops below 0.2 SOL.

3. **(spends)** Start it: `CLUSTER=mainnet-beta CONFIRM_MAINNET=yes scripts/kora_start.sh`. It prints the paymaster signer (`getPayerSigner`); that address is `KORA_PAYMASTER_SIGNER` for the APK.
4. Put the gateway behind TLS. A mainnet build accepts only `https` Kora URLs. With [Caddy](https://caddyserver.com) on a host with a DNS name (Caddy gets the certificates itself):

   ```
   # /etc/caddy/Caddyfile
   sponsor.<your-domain> {
       reverse_proxy 127.0.0.1:8080
   }
   paymaster.<your-domain> {
       reverse_proxy 127.0.0.1:8081
   }
   ```

   Then `sudo systemctl reload caddy`, and check `curl -s https://paymaster.<your-domain> -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"getPayerSigner"}'`.

5. Firewall: allow only 80/443 from outside. Kora binds `0.0.0.0` on 8090-8091 and the gateway on 8080-8081, so block those ports (`sudo ufw default deny incoming; sudo ufw allow 80,443/tcp; sudo ufw allow OpenSSH; sudo ufw enable`).

Behind a proxy, the gateway sees every client as `127.0.0.1` (`req.connectionInfo`), so its per-IP limit (60 requests/minute) becomes one limit shared by all users. Until the gateway reads `X-Forwarded-For` from the trusted proxy, raise `GATEWAY_PER_IP_MINUTE` or rate-limit per client IP in the proxy.

## 8. Keeper on mainnet

The keeper executes due tiers and vesting releases for everyone; the payout fee pays for it. Give it its own key and a small float **(spends)**:

```bash
solana-keygen new -o /etc/deadman/keeper.json --no-bip39-passphrase   # chmod 600, owned by the service user
solana transfer <KEEPER_ADDRESS> 0.1 --url "$RPC_URL" --allow-unfunded-recipient
dart run tool/keeper.dart --cluster mainnet-beta --keypair /etc/deadman/keeper.json \
  --rpc "$RPC_URL" --dry-run                                            # one read-only sweep
```

`--cluster mainnet-beta` selects mainnet USDC for pricing and refuses an RPC whose genesis hash is not mainnet. A sweep costs one `getProgramAccounts` (use a paid RPC); each execution costs about 5 000 lamports plus `--cu-price` (micro-lamports per compute unit). For token tiers the keeper also pays the beneficiary's and the treasury's token-account rent (0.00148844 SOL each), but only when the protocol fee is worth at least that rent at `--usdc-price-lamports` (lamports per USDC base unit = 1000 / the SOL price in USD; the default 6 means 1 USDC = 0.006 SOL, SOL at about $167). 0.1 SOL covers a few hundred executions.

systemd unit, `/etc/systemd/system/deadman-keeper.service`:

```ini
[Unit]
Description=Deadman keeper (mainnet)
After=network-online.target
Wants=network-online.target

[Service]
User=deadman
WorkingDirectory=/opt/deadman
EnvironmentFile=/etc/deadman/keeper.env
ExecStart=/opt/deadman/keeper --cluster mainnet-beta --keypair /etc/deadman/keeper.json --rpc ${RPC_URL} --every 60 --cu-price 20000 --usdc-price-lamports 6
Restart=always
RestartSec=30
NoNewPrivileges=true
ProtectSystem=strict
ReadOnlyPaths=/etc/deadman

[Install]
WantedBy=multi-user.target
```

```bash
dart compile exe tool/keeper.dart -o /opt/deadman/keeper    # or ExecStart=dart run tool/keeper.dart ...
printf 'RPC_URL=%s\n' "$RPC_URL" | sudo tee /etc/deadman/keeper.env >/dev/null && sudo chmod 600 /etc/deadman/keeper.env
sudo systemctl daemon-reload && sudo systemctl enable --now deadman-keeper
journalctl -u deadman-keeper -f
```

The keeper logs only the RPC host, never the URL with its API key. A cron job (`* * * * * ... keeper ... ` without `--every`) works too, but it restarts the process every minute, which forgets its vesting release times (harmless: it then releases each due schedule once).

## 9. Mainnet APK

```bash
flutter build apk --release \
  --dart-define=CLUSTER=mainnet-beta \
  --dart-define=RPC_URL="$APP_RPC_URL" \
  --dart-define=WS_URL="${APP_RPC_URL/https/wss}" \
  --dart-define=CLOAK_RPC_URL="$APP_RPC_URL" \
  --dart-define=KORA_SPONSOR_URL=https://sponsor.<your-domain> \
  --dart-define=KORA_PAYMASTER_URL=https://paymaster.<your-domain> \
  --dart-define=KORA_PAYMASTER_SIGNER=<signer printed in step 7> \
  --dart-define=ONECLICK_JWT=<optional 1Click partner token> \
  --dart-define=ZCASH_FEE_RECIPIENT=<optional NEAR account for the 1Click app fee> \
  --dart-define=JUP_API_KEY=<key> --dart-define=JUP_REFERRAL_ACCOUNT=<account>
```

- `USDC_MINT` defaults to mainnet USDC (`EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v`) when `CLUSTER=mainnet-beta`; do not set it.
- `KORA_MAX_FEE` (default 3 USDC, in base units) caps what the app pays the paymaster per transaction. With margin pricing a vault creation costs about (0.0077 + 2 × 0.0015 SOL) × 1.15 at the SOL price; raise the cap if that exceeds 3 USDC.
- Without `KORA_PAYMASTER_SIGNER` a mainnet build refuses to pay fees in USDC (audit M-3); owners pay in SOL.
- Use a separate RPC key for the app (`APP_RPC_URL`). Every `--dart-define` value, API keys included, can be read out of the APK, so give that key low limits and allowed-origin or allowed-app restrictions if your provider has them. `api.mainnet-beta.solana.com` will not work for Cloak (403 to the WebView).
- Bump `version:` in `pubspec.yaml` and sign the release APK with the dApp Store key.

## 10. End-to-end test

`tool/mainnet_e2e.dart` exercises the deployed program, both private rails, vesting and closing with real but small amounts, from throwaway keys in a work directory. Run it after steps 3, 4 and (for `--paymaster`) 7.

1. Plan and fund (read-only, prints the owner address and the exact funding):

   ```bash
   dart run tool/mainnet_e2e.dart --workdir ~/deadman-e2e --dry-run --rpc "$RPC_URL" \
     --zcash-u1 <your shielded u1 from Zashi> --cloak-dest <a wallet you own> \
     --cloak-rpc "$RPC_URL"
   ```

   With the defaults it asks for about **0.122 SOL and 1 USDC** on the owner key. Send them from your own wallet.

2. Run **(spends)**:

   ```bash
   ONECLICK_JWT=<optional> dart run tool/mainnet_e2e.dart --cluster mainnet-beta --rpc "$RPC_URL" \
     --workdir ~/deadman-e2e --zcash-u1 <u1> --cloak-dest <wallet> --cloak-rpc "$RPC_URL" \
     --return-to <your wallet> --i-funded-this
   ```

What it does, in order: (a) creates an inheritance plan (`create_plan`) with two tiers due 120 s after the last check-in: 0.05 SOL to claim key A on the Zcash rail and 0.035 SOL (or `--cloak-usdc 2` USDC) to claim key B on the Cloak rail, and deposits; (b) waits until they are due and executes them with the keeper's payability check; (c) routes claim key A through 1Click to your u1 and tracks it to `SUCCESS` (about 3 minutes); (d) routes claim key B through Cloak in headless Chromium (`tool/cloak_bundle/live.mjs`: deposit, proof, private send to `--cloak-dest`) and checks what arrived; (e) creates a 1 USDC vesting plan over 60 s, releases it once and checks the heir got it minus 2%; (f) closes both plans and sweeps every key (owner, guard, claim keys, heir; SOL and USDC, closing token accounts) to `--return-to`. It prints a summary table with Solscan links and the funds started, swept back, delivered and spent.

Expected spend with the defaults: protocol fees 0.00425 SOL and 0.02 USDC (to your treasury), the 1Click spread (about 0.002 SOL), the Cloak exit fee (0.005 SOL + 0.3%), the vesting vault's USDC account rent (0.0015 SOL; `close_vault` leaves token accounts), the treasury's USDC account if it is new (0.0015 SOL) and network fees: about **0.015 SOL and 0.02 USDC**. The ZEC (about 0.004 ZEC for 0.0475 SOL on 2026-10-04) arrives in your Zcash wallet, and about 0.023 SOL at `--cloak-dest`.

Every step is resumable: after any failure, fix the cause and run the same command again. `state.json` in the work directory records quotes, deposit addresses and signatures before anything is signed, so a rerun never pays twice (a Zcash quote that was saved but never sent is detected from the claim key's balance; an interrupted Cloak route resumes with the same amount, so the bundle finds its deposited note). Options: `--skip-zcash`, `--skip-cloak`, `--skip-vesting`, `--no-sweep`, `--paymaster https://paymaster.<your-domain>` (step e pays its fees in USDC through Kora: about 4 USDC more), `--cu-price`. `--cluster devnet` rehearses steps a, b, e and f on devnet. The work directory holds the keys (`owner.json`, `phrase.txt`, `cloak_claim.json`, mode 600): keep it until the summary says everything was swept, then delete it.

## Rollback and upgrades

- **No state rollback.** An upgrade replaces code, not accounts. To undo a bad upgrade, redeploy the previous verifiable binary through Squads (keep every released `.so` and its hash).
- **Layout.** `Vault` is final for mainnet: new fields must come out of `_reserved` (64 bytes) and keep `Vault::SPACE` at 1390, so existing accounts read with the new fields zeroed. Never reorder fields. `_reserved_interval` (the former check-in interval) is zero only on plans created after the 2026-10-05 rename; older accounts keep their old bytes there, so do not reuse that slot without a migration.
- **Instruction renames.** `create_vault` / `update_policy` became `create_plan` / `update_plan` without `interval_secs`. Their discriminators changed, so an old app build fails with `InstructionFallbackNotFound` (101) instead of misreading its arguments; ship the matching app and gateway together with the program. `Config` has no padding: a Config change needs a migration instruction.
- **Pausing.** The program has no pause switch. Stopping the Kora nodes (`scripts/kora_stop.sh`) and the keeper stops sponsored check-ins, USDC fees and automatic execution; owners and beneficiaries can still act from their own wallets. Shipping an app build with `KORA_*` unset forces SOL fees.
- **Freezing.** `solana program set-upgrade-authority $PROGRAM_ID --final` makes the program immutable forever, bugs included. Only after an audit and a long quiet period.
- **Closing.** `solana program close` returns the program-data rent but bricks every vault and frees nothing inside them. Never on mainnet with live vaults.

## Risks

- **Unaudited.** No external audit, fuzzing or formal review. The internal reviews ([2026-10-03](security-audit-2026-10-03.md), [2026-10-04](security-review-2026-10-04.md)) are by the same team that wrote the code. Cap what goes in (the app has no cap) and say so publicly.
- **Upgrade authority and fee admin.** Until step 6 the deploy key can replace the program. `Config.admin` cannot be rotated, so with option A the deploy key keeps control of the treasury address and fees (≤ 5%) forever.
- **Hot keys.** The Kora fee payer and the keeper key are hot keys on a server. The gateway and Kora's policy limit what they sign, but a compromised server loses their float and can grief users (refused check-ins, wrong fees up to `KORA_MAX_FEE`).
- **Paymaster economics.** Margin pricing depends on Jupiter's SOL price; a fast move between quote and landing costs Kora the difference. Failed paid transactions still cost Kora the fee (L-5).
- **Third parties.** 1Click and its solvers, Cloak's program and relay, Jupiter, Helius and Squads can fail, change APIs or censor. The Zcash rail's ZEC delivery and the Cloak relay withdrawal have never run with real funds until step 10.
- **Rent changes.** Mainnet rent already dropped once (a token account is 0.00148844 SOL, not 0.00203928). Code that hard-codes rent is wrong after such a change: `ZcashRoute.rentExemptLamports` (890 880) and `tokenAccountRentLamports` (2 039 280) are now higher than mainnet's 650 240 and 1 488 440, which only makes the app more conservative, and the Kora configs' comments still quote the 1318-byte vault. `rent_paid` protects sponsor rent in the program.
- **Claim keys** live on one phone and in its recovery phrase. A beneficiary who loses both before routing loses that payout.
- **Keeper scaling.** The keeper scans every vault with `getProgramAccounts` each sweep. Fine for hundreds of vaults; beyond that it needs an indexer.
- **Token accounts left behind.** `close_vault` does not close the vault's token accounts, so their rent is lost for every plan that held a token.
- **Privacy limits.** Private rails hide the link to the beneficiary's main wallet, not the payout itself: the claim key, amounts and timing are public on Solana (see the README's private-rails section).
- **APK secrets.** RPC, Jupiter and 1Click keys compiled into the APK are public in practice.

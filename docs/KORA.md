# Kora fee sponsor and USDC paymaster for Deadman (devnet)

Deadman runs [Kora](https://github.com/solana-foundation/kora) 2.0.5 nodes that share one signer:

- The **sponsor** pays the guard key's `pulse` / `lockdown` for free, so the phone's guard key never needs SOL. It also pays a beneficiary's own SOL claim (`execute_sol_rule` / `release_vested_sol`), so an heir with 0 SOL can claim: the program pays the heir from the vault.
- A beneficiary claiming **tokens** (USDC) with 0 SOL uses the paymaster: Kora pays the fee and any missing heir/treasury ATA, and the last instruction pays the USDC fee out of the payout the claim just delivered.
- The **paymaster** lets an owner who holds no SOL pay network fees in USDC (opt-in: Security tab, "Pay network fees with: SOL | USDC", `lib/state/fee_settings.dart`). It covers the network fee and, depending on the transaction, the rent of a new vault and of up to 2 token accounts. Kora's `fixed` pricing has one price per node, so there are **three paymaster nodes, one per price tier**, and the gateway picks the node by what Kora funds (see [Pricing](#pricing-paymaster)).

A small gateway (`tool/kora_gateway.dart`, one process) is the only public entry to any node (audit M-4):

| Process                    | Port | Auth                       | Purpose                                                                                                 |
| -------------------------- | ---- | -------------------------- | ------------------------------------------------------------------------------------------------------- |
| **gateway (sponsor)**      | 8080 | none (public)              | Accepts guard-signed `pulse` / `lockdown` and a beneficiary's own SOL claim, rate-limits, forwards      |
| **gateway (paymaster)**    | 8081 | none (public)              | Accepts owner-signed Deadman, deposit and payment instructions ending in a USDC payment; picks the tier |
| **sponsor**                | 8090 | `x-api-key` (gateway only) | Kora, `free` pricing: simulates, co-signs and sends. Pays the network fee                               |
| **paymaster plan tier**    | 8091 | `x-api-key` (gateway only) | Kora, fixed **3.00 USDC**. Pays the fee, one new vault's rent and up to 2 ATAs                          |
| **paymaster account tier** | 8092 | `x-api-key` (gateway only) | Kora, fixed **0.50 USDC**. Pays the fee and up to 2 ATAs                                                |
| **paymaster basic tier**   | 8093 | `x-api-key` (gateway only) | Kora, fixed **0.02 USDC**. Pays the network fee only (`allow_create_account = false`)                   |

Owners can still pay in SOL from their own wallet and skip Kora entirely (the default). The paymaster was added on 2026-10-04 and replaces the 2026-10-03 decision that there would be no token fee payment.

App URLs (same Wi-Fi): sponsor `http://<LAN>:8080`, paymaster `http://<LAN>:8081`. `kora_start.sh` prints both. The app reads them at build time:

```bash
flutter build apk \
  --dart-define=KORA_SPONSOR_URL=http://<LAN>:8080 \
  --dart-define=KORA_PAYMASTER_URL=http://<LAN>:8081 \
  --dart-define=USDC_MINT=<test mint>      # optional; default is Circle devnet USDC
```

Without `KORA_PAYMASTER_URL` the USDC option is disabled and owners pay in SOL. The app also pins the paymaster (audit M-3): `KORA_PAYMASTER_SIGNER` (default on devnet: the signer below) must be both the fee payer and the payment address Kora reports, and `KORA_MAX_FEE` (default 3 000 000 base units = 3 USDC) caps what one transaction may cost. Plain `http://` Kora URLs work only on devnet builds; see [Mainnet](#mainnet). `USDC_MINT` (`AppConfig.usdcMint`, `lib/core/config.dart`) must be a mint the paymaster accepts: Circle devnet USDC by default, or the `TEST_USDC_MINT` in `kora/.env`.

- Program: `ACHVLMoLDM3YPpGbNST4cZW4Tf2jx6nzJGuusyLJHofL` (devnet)
- Fee payer / signer: `HCAeeSv4vBHGqWLEV7AdWK19xFYuosN76jwUGuoCs3pL`

```
 phone (Seeker)                      this machine                                      devnet
 ─────────────                       ────────────                                      ──────
 guard key ── pulse/lockdown ──▶ gateway :8080 ── x-api-key ──▶ sponsor :8090 ── co-sign ──▶ RPC
 heir ── own SOL claim ─────────▶  │  policy + rate limits          │
                                   │  getMultipleAccounts ──────────┼──────────────────────▶ RPC
                                   kora/gateway-{usage,claims}.json  Redis :6379 (localhost)
 owner/heir wallet ── tx ending in a USDC payment ──▶ gateway :8081 ── x-api-key ─┬─▶ plan :8091 (3.00 USDC) ─┐
                                   │  policy + rate limits + tier             ├─▶ account :8092 (0.50 USDC) ─┼─ co-sign ─▶ RPC
                                   kora/paymaster-*.json                      └─▶ basic   :8093 (0.02 USDC) ─┘
                                                                     payment ATA BmGw5huq…CJ4L (USDC)
 owner wallet ── or anything, paying its own SOL ──────────────────────────────────────────▶ RPC
```

## Files

| Path                                                                                   | Purpose                                                                                                                                                                                                                                        |
| -------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `kora/sponsor.toml`                                                                    | Sponsor node config                                                                                                                                                                                                                            |
| `kora/sponsor.mainnet.toml`, `kora/paymaster.mainnet.toml`                             | Mainnet configs (`CLUSTER=mainnet-beta`): the same sponsor policy with mainnet USDC, and one margin-priced paymaster node ([Mainnet](#mainnet))                                                                                                |
| `kora/paymaster.toml`                                                                  | Paymaster config (plan tier). `kora_start.sh` (`render_tier`) renders `kora/paymaster-{plan,account,basic}.run.toml` (gitignored) with each tier's price, outflow cap, `allow_create_account` and metrics port, plus `TEST_USDC_MINT` when set |
| `kora/signers.toml`                                                                    | Signer pool: one memory signer, key read from `KORA_SIGNER_PRIVATE_KEY`                                                                                                                                                                        |
| `kora/.env`                                                                            | **Gitignored.** `KORA_SIGNER_PRIVATE_KEY`, `RPC_URL`, `SPONSOR_API_KEY` and `PAYMASTER_API_KEY` (both generated by `kora_start.sh` if absent), optional `TEST_USDC_MINT`                                                                       |
| `kora/.env.mainnet`                                                                    | **Gitignored.** The mainnet equivalent: `KORA_SIGNER_PRIVATE_KEY`, `RPC_URL` and `JUPITER_API_KEY` (required); the API keys are generated                                                                                                      |
| `tool/kora_gateway.dart`                                                               | Public gateway (both ports): method allowlists, transaction policies, rate limits, paymaster tier routing (`PaymasterTier`)                                                                                                                    |
| `kora/gateway-usage.json`, `kora/gateway-claims.json`, `kora/gateway-lockdowns.json` | **Gitignored.** Sponsor rate-limit timestamps (rolling 24 h): guard pulses, beneficiaries' SOL claims, and guard lockdowns (their own budget)                                                                                                                            |
| `kora/paymaster-usage.json`, `kora/paymaster-creates.json`, `kora/paymaster-atas.json` | **Gitignored.** Paymaster rate-limit timestamps: all paid transactions, Kora-funded vaults and Kora-funded token accounts. Mainnet uses `kora/mainnet/*.json`                                                                                  |
| `kora/fee-payer.json`                                                                  | **Gitignored.** Keypair file for the fee payer                                                                                                                                                                                                 |
| `kora/logs/*.log`, `kora/*.pid`                                                        | Runtime files (gitignored): `sponsor.log`, `paymaster.log` (plan tier), `paymaster-account.log`, `paymaster-basic.log`, `gateway.log`                                                                                                          |
| `scripts/kora_start.sh` / `kora_stop.sh`                                               | Start or stop Redis, the four Kora nodes and the gateway                                                                                                                                                                                       |
| `tool/e2e_usdc_vesting.dart`                                                           | Devnet end-to-end check: a 0-SOL owner creates, releases and closes a USDC vesting plan, paying fees in USDC ([results](#usdc-paymaster-end-to-end-2026-10-04-devnet))                                                                         |
| `tool/e2e_gasless_claims.dart`                                                         | Devnet end-to-end check: a 0-SOL heir claims a SOL tier through the sponsor and a USDC tier through the paymaster, fee from the payout ([results](#zero-sol-claims-end-to-end-2026-10-04-devnet))                                              |

## Install

```bash
# ~1.2 GB of build artifacts; build in a throwaway target dir, then delete it
CARGO_TARGET_DIR=/tmp/kora-target cargo install kora-cli --version 2.0.5 --locked
rm -rf /tmp/kora-target
kora --version   # kora-cli 2.0.5
```

The Docker alternative is the repo's `Dockerfile` (it builds from source as `rust:1.88`). There is no prebuilt image for 2.0.5 on a registry that we verified.

## Key setup (already done on this machine)

```bash
cd kora
umask 077
solana-keygen new --no-bip39-passphrase --silent -o fee-payer.json
printf 'KORA_SIGNER_PRIVATE_KEY=%s\nRPC_URL=https://api.devnet.solana.com\n' \
  "$(tr -d ' \n' < fee-payer.json)" > .env        # u8-array form; base58 also works
solana-keygen pubkey fee-payer.json
solana transfer "$(solana-keygen pubkey fee-payer.json)" 0.5 --allow-unfunded-recipient --url devnet
```

The memory signer accepts a base58 secret, a `[1,2,...]` u8 array, or a path to a keypair file (`solana-keychain` 0.1.0, `from_private_key_string`).

## Run

```bash
scripts/kora_start.sh        # Redis, sponsor :8090, paymaster tiers :8091-8093 (+ initialize-atas), gateway :8080/:8081; idempotent
scripts/kora_stop.sh         # stops the gateway and all Kora nodes
scripts/kora_stop.sh --all   # also stops Redis (counters persist in the `deadman-kora-redis` volume)
```

- Kora 2.0.5 always binds `0.0.0.0` (hard-coded in `run_rpc_server`). Only `--port` is configurable, so the API key is what closes :8090-8093: any call without it gets HTTP 401 (only the `liveness` method and `GET /metrics` bypass it). Phones use the gateway URLs the script prints (`KORA_SPONSOR_URL=http://<lan-ip>:8080`, paymaster `http://<lan-ip>:8081`). They must be on the same Wi-Fi, and the host firewall must allow TCP 8080 and 8081. Do not open 8090-8093.
- The gateway runs with `dart run tool/kora_gateway.dart` in its own process group (`kora/gateway.pid`) and logs to `kora/logs/gateway.log`. It reads these variables from the environment:
  - Sponsor: `SPONSOR_API_KEY`, `RPC_URL`, `GATEWAY_PORT`, `KORA_UPSTREAM`, `GATEWAY_STATE`, `GATEWAY_PER_VAULT`, `GATEWAY_PER_SIGNER`, `GATEWAY_GLOBAL`, `GATEWAY_PER_IP_MINUTE`; claims: `GATEWAY_CLAIMS_STATE` (`kora/gateway-claims.json`), `GATEWAY_CLAIMS_PER_VAULT` (12), `GATEWAY_CLAIMS_PER_SIGNER` (12), `GATEWAY_CLAIMS_GLOBAL` (500); lockdowns: `GATEWAY_LOCKDOWNS_STATE` (`kora/gateway-lockdowns.json`), `GATEWAY_LOCKDOWNS_PER_VAULT` (3), `GATEWAY_LOCKDOWNS_PER_SIGNER` (24), `GATEWAY_LOCKDOWNS_GLOBAL` (1000), `GATEWAY_LOCKDOWN_MIN_LAMPORTS` (10000000).
  - Paymaster (the 8081 listener exists only when `PAYMASTER_API_KEY` is set): `PAYMASTER_API_KEY`, `PAYMASTER_PORT`, `PAYMASTER_UPSTREAM` (plan tier, :8091), `PAYMASTER_ACCOUNT_UPSTREAM` (:8092), `PAYMASTER_BASIC_UPSTREAM` (:8093), `PAYMASTER_STATE`, `PAYMASTER_PER_OWNER`, `PAYMASTER_GLOBAL`, `PAYMASTER_CREATES_STATE`, `PAYMASTER_CREATES_PER_OWNER`, `PAYMASTER_CREATES_GLOBAL`, `PAYMASTER_ATAS_STATE`, `PAYMASTER_ATAS_PER_OWNER` (6), `PAYMASTER_ATAS_GLOBAL` (100).

  The app needs no API key: the gateway adds it.

- On start, the paymaster listener reads each tier node's `getConfig` to get its fixed price and `allowed_spl_paid_tokens` (`loadPaymentAtas`). With `margin` pricing (mainnet) there is no fixed price, so the gateway sets no floor and Kora prices and checks the payment. It reads each mint's token program and decimals, converts every tier price to each mint's decimals, and derives the payment ATAs from `getPayerSigner.payment_address`. All tiers must accept the same mints. Change prices only in `kora/paymaster.toml` (plan) and `render_tier` in `kora_start.sh` (account, basic), then restart.
- CLI shape: `kora --config <toml> --rpc-url <url> rpc start --signers-config <toml> --port <n>`. The global flags come before `rpc`, and `RPC_URL` is also read from the environment.
- `KORA_API_KEY` and `KORA_HMAC_SECRET` in the environment override `[kora.auth]`. The start script clears both and sets `KORA_API_KEY` per node, from `SPONSOR_API_KEY` or `PAYMASTER_API_KEY` (shared by the three paymaster tiers). On first run it appends a random key (`openssl rand -hex 32`) for each to `kora/.env`. Never print them. Kora's startup validation still warns "No authentication configured", because it checks the TOML before the env override. The 401 checks below show the key is enforced.
- Check a config: `kora --config kora/sponsor.toml --rpc-url $RPC_URL config validate-with-rpc --signers-config kora/signers.toml` (the same for each `kora/paymaster-*.run.toml`)
- Payment ATAs: `kora --config kora/paymaster-plan.run.toml --rpc-url $RPC_URL rpc initialize-atas --signers-config kora/signers.toml` creates the signer's ATA for every `allowed_spl_paid_tokens` mint (fee payer pays the ATA rent). `kora_start.sh` runs it on every start; once the ATAs exist it does nothing. Devnet USDC ATA: `BmGw5huqX9EaddNKjPHeC8Gp5yBkdPSScd1tejhMCJ4L`.

## Sponsor gateway policy (:8080, `tool/kora_gateway.dart`)

Kora cannot filter by instruction, and its usage limit is skipped when Kora is the only signer (audit M-4). The gateway closes both:

- Methods: `getPayerSigner` (served from a cache), `getBlockhash` (cached 1 s) and `signAndSendTransaction`. Anything else gets JSON-RPC error `-32601`. Bodies over 8 KiB get HTTP 413, and more than 60 requests per minute from one IP get HTTP 429.
- `signAndSendTransaction` forwards only `{transaction}` (legacy or v0, no address lookup tables), and only if all of these hold:
  - exactly 2 required signatures, account 0 is the Kora payer, and the other signer's signature is valid (so nobody can burn a vault's quota with unsigned copies);
  - every instruction is a ComputeBudget `SetComputeUnitLimit` (≤ 60 000) or `SetComputeUnitPrice`, or a Deadman `pulse` / `lockdown` (exact 8-byte discriminator, no other data), or one SOL claim (below);
  - 1 to 8 Deadman instructions, each with that signer as its first account, and no instruction references the Kora account;
  - the fee, 2 × 5 000 + ceil(CU limit × price / 10⁶), is at most 50 000 lamports (with no CU limit, 200 000 CU per instruction is assumed);
  - for pulses and lockdowns, every vault (`getMultipleAccounts`) is owned by the program, has the Vault discriminator, and has `guard` (offset 42) equal to the signer. The signer may not be the vault owner (offset 8) or its guardian, whose transactions are not sponsored.
- **SOL claims.** A transaction may instead carry exactly **one** Deadman `execute_sol_rule` or `release_vested_sol` (discriminator + 1-byte rule index, exactly the 5 IDL accounts: executor, vault, config, beneficiary, treasury) and no pulse/lockdown:
  - its executor (account 0) **and** its beneficiary (account 3) are both the signer: the beneficiary claims for itself; the config account is the config PDA; Kora appears in no instruction;
  - on chain (`getMultipleAccounts`), the vault is program-owned, has the Vault discriminator and the current 1 390-byte layout, and rule `index` exists, names the signer as beneficiary, pays SOL (`mint = None`), is not fully paid (`executed_at = 0`), and the plan kind matches (inheritance for `execute_sol_rule`, vesting for `release_vested_sol`);
  - token claims (`execute_token_rule` / `release_vested_token`) are refused with `Token claims are not sponsored: send them to the paymaster …`.

  The program pays the heir from the vault; Kora only pays the network fee (no CPI, no fee-payer outflow). A brand-new heir account must end rent-exempt: if the heir's balance plus the net payout is below `getMinimumBalanceForRentExemption(0)` (650 240 lamports on devnet today, not the older 890 880) the program fails (`BeneficiaryCannotReceive`), Kora's simulation rejects it, and the quota is given back.

- A transaction signed only by Kora therefore never reaches Kora.
- Rate limits over a rolling 24 h: 24 sponsored transactions per vault, 48 per guard key and 2 000 in total. **Lockdowns** have a budget of their own (audit M-3), so pulses and claims can never use it up: 3 per vault, 24 per guard key and 1 000 in total (`GATEWAY_LOCKDOWNS_PER_VAULT`, `GATEWAY_LOCKDOWNS_PER_SIGNER`, `GATEWAY_LOCKDOWNS_GLOBAL`, persisted in `GATEWAY_LOCKDOWNS_STATE`, default `kora/gateway-lockdowns.json`). A lockdown is sponsored only if at least one of its vaults is a current-layout, non-revoked plan with a payout still pending that holds at least `GATEWAY_LOCKDOWN_MIN_LAMPORTS` (default 10 000 000, 0.01 SOL) above rent, or a balance of a token its pending rules pay (vault rent is read from the RPC at startup). Lockdowns may not share a transaction with pulses, and a refused lockdown uses no quota. Claims have their own counters (`kora/gateway-claims.json`): 12 per vault, 12 per claimer and 500 in total (worst case 500 × 50 000 lamports = 0.025 SOL per day). A forwarded transaction counts unless Kora rejects it (a JSON-RPC error or an HTTP refusal gives the slot back). A timeout keeps it, since the transaction may have been sent. The counters persist in `kora/gateway-usage.json`. Rejections are JSON-RPC `-32000` errors with a readable message, for example `Rate limit: vault … reached 24 sponsored transactions per 24h; retry after …`.
- Worst case drain: 2 000 × 50 000 lamports = 0.1 SOL per day. A normal guard pulse costs 10 000 lamports.
- Reset a vault's counter: stop the gateway, edit `kora/gateway-usage.json`, then start it again.

## Paymaster gateway policy (:8081)

Methods: `getPayerSigner` (cached), `getBlockhash` (cached 1 s), `estimateTransactionFee` and `signAndSendTransaction`. Anything else gets `-32601`. Only `{transaction}` is forwarded, plus `fee_token` for estimates. `signAndSendTransaction` is forwarded only if all of these hold (`validatePaymasterTx`, which is pure and covered by `test/tool/kora_gateway_test.dart`):

- Exactly 2 required signatures: account 0 is the Kora payer and account 1 is the owner. The owner's ed25519 signature must verify, so nobody can spend an owner's quota or Kora's rent float with unsigned copies.
- Legacy or v0 with no lookup tables, 1 to 12 instructions. Each top-level instruction is one of the following:
  - ComputeBudget `SetComputeUnitLimit` (≤ 400 000) or `SetComputeUnitPrice`, each at most once. The fee, 2 × 5 000 + ceil(limit × price / 10⁶), must be ≤ 50 000 lamports.
  - Associated Token `CreateIdempotent` paid by the owner or by Kora. Kora may be only its payer, and at most 2 Kora-paid ATAs per transaction (`maxKoraAtas`). Kora pays only for an ATA that the rest of the transaction pays into (audit M-1):
    - a vault's ATA, when a `TransferChecked` of that mint (amount > 0) goes into it and the wallet is the vault of a Deadman instruction in the transaction (`create_vesting` with a deposit) or, otherwise, a Deadman vault on chain (`getMultipleAccounts`: program-owned, Vault discriminator; a plain deposit);
    - the beneficiary's or the treasury's ATA of an `execute_token_rule` / `release_vested_token` in the transaction, with its mint (the program binds them to the beneficiary and `Config.treasury`).

    Anything else is refused. That includes the signer's own ATA, except as the beneficiary ATA of the signer's own claim (a `withdraw_token` into a closed account is paid by the owner), and the review's PoC (two Kora-paid ATAs on the attacker's own wallet).

  - SPL Token or Token-2022 `TransferChecked` / `Transfer`, single signer, with the owner as authority.
  - System `Transfer` from the owner (a SOL deposit).
  - A Deadman instruction from the allowlist: `create_plan`, `create_vesting`, `update_plan`, `set_guard`, `pulse`, `lockdown`, `withdraw_sol`, `withdraw_token`, `execute_sol_rule`, `execute_token_rule`, `skip_rule`, `release_vested_sol`, `release_vested_token`, `revoke_vesting`, `close_vault`. Each has its exact IDL account count, and the owner is its first account. `create_plan`, `create_vesting` and `update_plan` may carry up to 8 extra read-only mint accounts (the token mints the rules name), and `withdraw_token` up to 8 Token-2022 hook accounts; payouts (`execute_*`, `release_vested_*`) take no extra accounts. When a token payout leaves the treasury no fee, its `treasury_token` slot is the program id, and Kora never opens an account for it. `init_config`, `set_config`, `propose_admin`, `accept_admin` and `unlock` (3 signers) are refused. Owner exits take no protocol fee and name no treasury or config account: `withdraw_sol` has 2 accounts, `withdraw_token` 6 (plus hook accounts) and `close_vault` 3, and a `withdraw_token` credits its full amount to the owner's token account in the payment check.
- Kora appears only as the fee payer, as the `payer` of `create_plan` / `create_vesting` (at most one per transaction, which bounds the rent outflow to one account; Kora-funded creation is refused at a plan address that already holds lamports, because the program would then top it up with a System transfer that Kora's `allow_transfer = false` rejects, so Kora always pays the full rent the plan price assumes), as the payer of at most 2 ATA creates, or as the `rent_payer` of `close_vault`, where it is a lamport destination only. It is never a token account, token authority, wallet, System transfer source or destination, or any other Deadman account.
- **Tier.** What Kora funds picks the tier and the Kora node (`PaymasterTier`, `upstreamFor`): a Kora-paid create → **plan**; otherwise any Kora-paid ATA → **account**; otherwise **basic**.
- The **last** instruction is the payment: a token transfer to a paymaster payment ATA, with that ATA's mint and token program, of at least the tier's price in that mint's decimals (3 000 000, 500 000 or 20 000 base units of USDC). Kora checks the payment value again.
- The payment must be able to succeed (audit M-2). Before anything is forwarded, the payment's source must be the owner's unfrozen token account of the payment mint (`getMultipleAccounts`). It must hold every transfer the transaction takes from it, the payment included, minus what a `withdraw_token` in the transaction pays into it. It may be missing only when an ATA create in the same transaction opens it.
- **Claims funded by their payout.** When an `execute_token_rule` / `release_vested_token` earlier in the transaction has the signer as beneficiary, pays the payment mint, and its beneficiary token account is the payment source, the payout is what funds the fee (`PaymasterRequest.fundingClaim`). Its amount depends on vault state, so the gateway skips the balance check and Kora's simulation decides. Instead, the vault is checked on chain: program-owned, current layout, plan kind matching the instruction, and rule `index` names the signer, pays that mint and is not fully paid. The source must still be the signer's unfrozen account of the mint, or be opened in the transaction (Kora-funded, account tier). Quota is still given back if Kora rejects. A heir with no SOL and no USDC claims with `[ATA create(payer = Kora, heir), (ATA create(payer = Kora, treasury) if missing), claim, transfer_checked(heir ATA → payment ATA, fee)]`: **account** tier (0.50 USDC) when Kora opens an ATA, **basic** (0.02 USDC) otherwise.
- Rate limits over a rolling 24 h, persisted in `kora/paymaster-*.json`:
  - 60 paid transactions per owner and 2 000 in total.
  - Kora-funded vaults separately: 3 per owner and 20 in total, which bounds the locked vault-rent float to about 0.15 SOL per day.
  - Kora-funded token accounts separately, one slot per ATA: 6 per owner and 100 in total, which bounds the ATA rent that Kora spends for good to about 0.2 SOL per day.

  Every quota is checked first, then the accounts, and the quota is taken only when both pass. If Kora rejects the transaction (a JSON-RPC error or an HTTP refusal), all of it is given back, so wallets that cannot pay cannot use it up. A timeout keeps it.

- `estimateTransactionFee` runs the same structural checks but does not need the payment or a valid signature: the client prices first, then appends the payment and signs. `fee_token` must be an accepted mint. The estimate goes to the tier's node, and the gateway raises the returned `fee_in_token` to the tier price (`minFee`), because Kora's Mock oracle may quote less for a mint other than the configured price token (see `TEST_USDC_MINT` below).

Client flow (`DeadmanClient._buildPaid`, `lib/solana/deadman_client.dart`): call `getPayerSigner` and require `signer_address` and `payment_address` to equal the pinned `AppConfig.koraPaymasterSigner` (`KoraUntrusted` otherwise; an empty pin is `KoraUnpinned`), then call `getBlockhash`. Build the message with Kora as fee payer and, where the app lets Kora fund accounts, Kora as `payer` of `create_plan` / `create_vesting` and of new ATAs (vault ATA on a USDC deposit, beneficiary and treasury ATAs on a token release). Drop every Kora-paid ATA create whose ATA already exists (`_withoutExistingKoraAtas`), so the owner lands in the cheapest tier that fits. A missing `withdraw_token` destination is paid by the owner instead (`NoSolForAccount` if the wallet lacks the 0.00204 SOL). Call `estimateTransactionFee` with `fee_token` = USDC to get `fee_in_token`. Check that the estimate names the pinned key too and that the fee is at most `AppConfig.koraMaxFee` (`KoraFeeTooHigh`), and that the wallet holds the fee plus any USDC moved. Append `transferCheckedIx(owner USDC ATA → the pinned key's USDC ATA, fee_in_token, 6)` as the last instruction, have the owner sign, and call `signAndSendTransaction` once.

## Pricing (paymaster)

Kora's `fixed` mode charges one amount per node and cannot price `create_plan` differently from a `pulse`. Deadman therefore runs one node per tier, and the gateway routes each transaction by what Kora funds:

| Tier        | Port | Price         | Kora funds                                    | `max_allowed_lamports` | `allow_create_account` | Typical transactions                                                         |
| ----------- | ---- | ------------- | --------------------------------------------- | ---------------------- | ---------------------- | ---------------------------------------------------------------------------- |
| **plan**    | 8091 | **3.00 USDC** | one new vault's rent + up to 2 ATAs + the fee | 11 500 000             | true                   | `create_plan` / `create_vesting` (with a USDC deposit into a new vault ATA) |
| **account** | 8092 | **0.50 USDC** | up to 2 ATAs + the fee                        | 4 150 000              | true                   | first USDC deposit into a plan, a token claim that opens the heir's ATA      |
| **basic**   | 8093 | **0.02 USDC** | the network fee only                          | 60 000                 | false                  | edits, pulses, withdrawals, later releases, `close_vault`                    |

- Vault size: `Vault::SPACE` = 8 + 1 382 = **1 390 bytes**. That is 32 owner + 2 plan_id + 32 guard + 33 guardian + 8 × 8 timestamps and counters + 2 × 4 streaks + 1 kind + 8 start_at + 1 revocable + 8 revoked_at + 32 rent_payer + 8 rent_paid + (4 + 8 × 131) rules + (4 + 32) label + 1 bump + 64 reserved.
- Rent: vault **7 711 440 lamports** (`getMinimumBalanceForRentExemption(1390)`), ATA (165 bytes) **1 488 440 lamports** (Token-2022, 170 bytes: 1 513 840), same on devnet and mainnet today. The network fee is capped at 50 000 lamports by the gateway.
- Outflow caps: plan 7 711 440 + 2 × 1 488 440 + 50 000 = 10 738 320 ≤ 11.5M; account 2 × 1 488 440 + 50 000 = 3 026 880 ≤ 4.15M (below a vault's rent, so this tier can never fund a vault); basic ≤ 60 000. Kora applies `max_allowed_lamports` separately to the fee payer's outflow and to the network fee, so a second Kora-funded create in one transaction fails in Kora as well as in the gateway.
- Coverage: 3.00 USDC covers 11.5M lamports up to SOL ≈ $260; 0.50 USDC covers one ATA and the fee (1 538 440 lamports at the 50 000 fee cap) up to SOL ≈ $325, two ATAs (3 026 880) up to ≈ $165 and the 4.15M cap up to ≈ $120; 0.02 USDC covers 60 000 lamports up to SOL ≈ $330.
- **Vault rent comes back.** The program stores `vault.rent_payer` (Kora here) and `close_vault` returns the rent to it; anything above rent goes to the owner (`handle_close_vault`). ATA rent paid by Kora does not come back: those ATAs belong to the vault, the heir or the treasury.
- `strict = false`. Kora converts the fixed amount to lamports with the price oracle. With the `Mock` source, devnet USDC is priced at 0.0001 SOL, so 3 USDC "is" 300 000 lamports. Strict mode would therefore reject every Kora-funded create (outflow 7.35M > 300k). Non-strict fixed mode requires a payment worth ≥ the fixed amount, priced with the same oracle, so the comparison stays consistent.
- `TEST_USDC_MINT`: the Mock oracle prices unknown mints at 0.001 SOL, ten times devnet USDC, so Kora alone would accept, and quote, a tenth of the price in a test token. The gateway closes both: it requires ≥ the tier price in base units of every accepted mint, after adjusting for decimals, and raises `estimateTransactionFee`'s `fee_in_token` to that price.
- **Mainnet** uses margin pricing on one node instead of the three fixed tiers; see [Mainnet](#mainnet).

## Node policies

These apply to every node unless a node's section says otherwise.

- Only allowlisted programs may appear in **any** instruction. Kora simulates the transaction (`innerInstructions: true`) and checks CPIs too.
- The fee payer policy denies everything: no SOL transfer, assign, allocate or nonce use, and no SPL/Token-2022 transfer, approve, burn, close, set-authority, mint, init or freeze. The one exception is the plan and account paymaster tiers, which may fund account creation.
- `transfer_transaction` is disabled. It would let callers make the fee payer create ATAs. Disabled methods return HTTP 405 with an empty body.
- `allow_durable_transactions = false`.
- `rate_limit = 20`: a global requests-per-second cap for the node, not per wallet.
- Sponsor only: a per-wallet usage limit (`[kora.usage_limit]`) through Redis. The key is `kora:usage_limit:<wallet>`, where the wallet is the first signer that is not Kora. It is a **lifetime** counter with no time window. It counts every `signTransaction` / `signAndSendTransaction` call, including rejected ones. It fails closed if Redis is down.

### paymaster tiers (8091, 8092, 8093)

The three nodes share one config (`kora/paymaster.toml`, rendered per tier by `render_tier` in `kora_start.sh`), one signer and one API key. Only the price, `max_allowed_lamports`, `allow_create_account` and the metrics port differ ([Pricing](#pricing-paymaster)).

- `allowed_programs`: Deadman, System, SPL Token, Token-2022, Associated Token and Compute Budget. Kora checks CPIs too.
- `fee_payer_policy`: only `system.allow_create_account` may be `true` (plan and account tiers), which is what Anchor's `init` with `payer = Kora` and the Associated Token program's create use. Everything else is `false`, and the basic tier sets `allow_create_account = false`. Kora's config validator warns about this; the gateway is the guard (Kora is only allowed in the `payer` slot of one create and at most 2 ATA creates per transaction).
- `max_allowed_lamports`: 11 500 000 (plan), 4 150 000 (account), 60 000 (basic).
- `max_signatures = 2`, `allow_durable_transactions = false`, `transfer_transaction = false`.
- Pricing: `fixed`, 3 000 000 / 500 000 / 20 000 base units of devnet USDC, `strict = false`, `price_source = "Mock"`. `allowed_tokens` and `allowed_spl_paid_tokens` are Circle devnet USDC `4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU` (6 decimals), plus `TEST_USDC_MINT` from `kora/.env` when it is set.
- No Kora usage limit (`[kora.usage_limit] enabled = false`). Every transaction is paid, and Kora's counter is lifetime-only. The gateway's rolling per-owner limits apply instead.
- Payments go to the signer's ATAs (no `payment_address`), so the USDC sits on the same hot key. Sweep it regularly.

### sponsor (8090)

- `allowed_programs`: Deadman and Compute Budget only.
- `max_allowed_lamports = 50_000`. This caps the network fee: two signatures (10 000) plus at most 40 000 lamports of priority fee. Fee payer outflow must also be at most 50 000, but every outflow path is already blocked.
- `max_signatures = 2` (Kora plus the guard key or the claiming beneficiary).
- Usage limit: 1 000 signs per guard key or claimer (Redis DB 0).
- Kora cannot filter by instruction discriminator; the gateway does. As a second line, `create_plan` and token rules fail here anyway, because their CPIs hit System or Token, which are not allowlisted. `execute_sol_rule` / `release_vested_sol` move lamports directly (no CPI), so they pass with the same config; no config change was needed for claims. Verified: `Program 11111111111111111111111111111111 is not in the allowed list`.
- `allowed_tokens` must be non-empty or Kora will not start, so it lists devnet USDC. Nothing is accepted as payment, and `estimateTransactionFee` with `fee_token` errors with `Token … is not supported`.

## Mainnet

Mainnet runs the same program id (`ACHVLMoLDM3YPpGbNST4cZW4Tf2jx6nzJGuusyLJHofL`, deployed from the same program keypair), the same gateway and the same policies. What changes:

| Item          | Devnet                                              | Mainnet                                                                                          |
| ------------- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Configs       | `sponsor.toml`, `paymaster.toml` → 3 tier nodes     | `sponsor.mainnet.toml`, `paymaster.mainnet.toml` → 1 paymaster node on :8091 for every tier      |
| Pricing       | fixed 3.00 / 0.50 / 0.02 USDC, `Mock` oracle        | `margin = 0.15`, `price_source = "Jupiter"`: ceil((network fee + Kora's outflow) × 1.15) in USDC |
| USDC          | `4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU`      | `EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v`                                                   |
| Secrets       | `kora/.env`                                         | `kora/.env.mainnet`: `KORA_SIGNER_PRIVATE_KEY`, `RPC_URL`, `JUPITER_API_KEY`; API keys generated |
| Gateway state | `kora/*.json`, Redis DBs 0-1                        | `kora/mainnet/*.json`, Redis DBs 2-3                                                             |
| App Kora URLs | `http://<LAN>:8080` / `:8081` allowed               | `https://` only (`KoraClient.checkUrl`), behind a TLS reverse proxy for :8080 / :8081            |
| App pin       | `KORA_PAYMASTER_SIGNER` defaults to `HCAeeSv4…s3pL` | `KORA_PAYMASTER_SIGNER` must be set, or paying in USDC is refused (`KoraUnpinned`)               |

Margin pricing includes the fee payer's outflow, CPIs included: Kora 2.0.5 runs `calculate_fee_payer_outflow` over the simulated inner instructions. So every Kora-funded vault or ATA costs its buyer more than its rent at the oracle price, which closes M-1 on mainnet by price as well as by the gateway's ATA rule. The fee payer policy, `max_allowed_lamports = 11 500 000` and the gateway caps are the same as on devnet.

At SOL ≈ $200, a plan with a vault and 2 ATAs costs about 2.65 USDC. That stays under the app's default `KORA_MAX_FEE` of 3 USDC only while SOL is below about $225, so set `KORA_MAX_FEE` for mainnet builds.

Start the stack after the mainnet program deploy. It spends mainnet SOL: the payment ATA, and every fee and rent Kora pays.

```bash
# kora/.env.mainnet (mode 600): KORA_SIGNER_PRIVATE_KEY=..., RPC_URL=https://<mainnet rpc>, JUPITER_API_KEY=...
CLUSTER=mainnet-beta CONFIRM_MAINNET=yes scripts/kora_start.sh
scripts/kora_stop.sh
```

Check the configs first with `kora --config kora/paymaster.mainnet.toml --rpc-url "$RPC_URL" config validate-with-rpc --signers-config kora/signers.toml` (with `JUPITER_API_KEY` set), and the same for `sponsor.mainnet.toml`. Both already pass `config validate` offline.

App build:

```bash
flutter build apk --dart-define=CLUSTER=mainnet-beta \
  --dart-define=RPC_URL=<mainnet rpc> \
  --dart-define=KORA_SPONSOR_URL=https://<host>:8080 \
  --dart-define=KORA_PAYMASTER_URL=https://<host>:8081 \
  --dart-define=KORA_PAYMASTER_SIGNER=<getPayerSigner.signer_address> \
  --dart-define=KORA_MAX_FEE=<cap in USDC base units>
```

A mainnet build with an `http://` Kora URL throws at startup (`ArgumentError` from `KoraClient.fromConfig`), so the mistake shows on the first run.

Still to verify on mainnet:

- Jupiter prices USDC as expected.
- A payment exactly equal to the estimate passes Kora's check when it lands. The estimate and the check use the oracle price at different times.
- The end-to-end flow of `tool/e2e_usdc_vesting.dart`.

Use a remote signer rather than a hot key in an env file.

## Verified live against devnet

The runs below predate the 2026-10-05 rename: `create_vault` / `update_policy` are now `create_plan` / `update_plan` (new discriminators, no `interval_secs` argument). The gateway now refuses the old discriminators.

Before the gateway (direct to Kora):

| Test                                           | Result                                                                |
| ---------------------------------------------- | --------------------------------------------------------------------- |
| guard `pulse` through `signAndSendTransaction` | landed, fee paid by Kora (sig `5xUxL1TS…C7Db`)                        |
| `pulse` signed by a stranger                   | rejected in simulation (`custom program error: 0x1770`, Unauthorized) |
| `create_vault`                                 | `Program 1111… is not in the allowed list`                            |
| 200k CU × 1 000 000 µlamports priority fee     | `Fee 205000 exceeds maximum allowed 50000`                            |

With the gateway (2026-10-03):

| Test                                                  | Result                                                                            |
| ----------------------------------------------------- | --------------------------------------------------------------------------------- |
| `getPayerSigner` / `getBlockhash` through :8080       | OK                                                                                |
| `getConfig` through :8080                             | `-32601 Method getConfig is not available on the Deadman sponsor`                 |
| any method on :8090 without or with a wrong key       | HTTP 401                                                                          |
| ComputeBudget-only transaction, Kora the only signer  | `Sponsored transactions need exactly 2 signatures: the sponsor and the guard key` |
| pulse on a live vault signed by a stranger            | `<key> is not the guard key of vault <vault>`                                     |
| pulse naming the vault's guard, signature left zeroed | `Invalid guard signature`                                                         |
| guard-signed `skip_rule`                              | `Only Deadman pulse and lockdown are sponsored`                                   |

## Paymaster smoke test (2026-10-04, devnet)

| Test                                                                                | Result                                                                                                      |
| ----------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `getPayerSigner` through :8081                                                      | OK, `HCAeeSv4…s3pL`                                                                                         |
| any method on :8091 without or with a wrong key                                     | HTTP 401                                                                                                    |
| `getConfig` through :8081                                                           | `-32601 Method getConfig is not available on the Deadman paymaster`                                         |
| `estimateTransactionFee` (create_vault, Kora payer, `fee_token` USDC) through :8081 | `fee_in_lamports: 300000, fee_in_token: 3000000`                                                            |
| `signAndSendTransaction` of that create_vault without a payment                     | gateway: `The last instruction must pay the paymaster: a token transfer to BmGw5huq…CJ4L`                   |
| same create_vault + 3 USDC payment from an owner with no USDC                       | passes the gateway; Kora: `simulation failed: Error processing Instruction 1: invalid account data`         |
| unpaid create_vault, `signTransaction` direct on :8091 (with key)                   | `Insufficient token payment. Required 300000 lamports`: programs, CPI create_account and 7.35M outflow pass |
| the paid create_vault through the sponsor :8080                                     | `Instructions may not reference the sponsor account`                                                        |

That smoke test ran against the single 3 USDC node that preceded the tiers.

## USDC paymaster end to end (2026-10-04, devnet)

`dart run tool/e2e_usdc_vesting.dart --mint <test mint>` with the test mint `Ew8Z6hhRp7MFK8KJAxRqaBQvBEjtRj4Y4K4YhWsPMFGk` accepted through `TEST_USDC_MINT` (6 decimals; this machine holds no Circle devnet USDC, faucet: https://faucet.circle.com). A fresh owner holding **0 SOL** and 20 test USDC created a revocable vesting plan of 10 USDC to a fresh heir (no cliff, 90 s), released twice and closed it. Every transaction was paid in USDC through :8081.

| Step                                                              | Tier    | Owner paid | Signature                                                                                  |
| ----------------------------------------------------------------- | ------- | ---------- | ------------------------------------------------------------------------------------------ |
| `create_vesting` + 10 USDC deposit (Kora: vault + vault ATA rent) | plan    | 3.00 USDC  | `3kQi625SuoQVJ3dTyLtHViwibgW3w7kq5HUygmLTzNq1tas4ZVeqwPk8Fv66vzdL8fQNubvGPKt2Vshb3LiK7Vp4` |
| `release_vested_token` #1 (Kora: heir ATA)                        | account | 1.00 USDC  | `5qq4m9LYDoaRt2WehJqqdz1v81snUywy5tteojg2Yinr7XEPBgnUnWX4KzsRvsANqyv42ntg4cyNVCX2gvCSvpkv` |
| `release_vested_token` #2 (fully vested, ATAs exist)              | basic   | 0.02 USDC  | `4uJQbZFmYiUfiyTYM7QyMte4RaQXGpK1oJNUDevjxqV3crHEHNTGTiWKMQUAHKfapdBhj365U48hFiN8xP4f5JpX` |
| `close_vault` (vault rent back to Kora)                           | basic   | 0.02 USDC  | `2oSV6gm8zbdsQX4BMpoLxBHf5Z6dpWxPSzC2k9UAoxNmsZPZmABiUUMpAdikZwoaKG82S5ztj62fbt33z1dsk9PM` |

- The heir received **9.800001 USDC**: 10 USDC minus the Solana-rail fee configured at the time (2%, the default again since 2026-10-08), which each release rounds down (two releases, one unit more for the heir).
- The account tier cost 1.00 USDC at the time; it is 0.50 USDC since 2026-10-04.
- Release #2 landed in the basic tier because the client dropped the Kora-paid ATA creates for ATAs that already existed (`_withoutExistingKoraAtas`).

## Zero-SOL claims end to end (2026-10-04, devnet)

`dart run tool/e2e_gasless_claims.dart` (defaults: the test mint, :8080, :8081, public devnet RPC). A scratch owner funded from the CLI wallet (0.3 SOL, 5 test USDC) created an inheritance plan (then with a 60 s check-in interval, since removed) with two tiers for a fresh heir holding **0 SOL**: 0.002 SOL and 1 USDC, both fixed, both 120 s after the last check-in (then the program's minimum, interval + 60 s; today any wait from 60 s up is allowed). The heir claimed both as soon as the chain clock passed the due time, before the keeper.

| Step                                                                         | Fee payer                   | Heir paid                                 | Signature                                                                                  |
| ---------------------------------------------------------------------------- | --------------------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------ |
| `create_vault` + 0.002 SOL + 1 USDC deposits (owner, wallet-paid)            | owner                       | -                                         | `2sJZTWWgR5yYquzk9SgwEoTJfmRbP8mBmPmvL7dTbSzoq8TphaGzfqbJaSQsnscaV98k2BwCJ3aZ9TGHiw9EUeDR` |
| `execute_sol_rule` #0 through the sponsor :8080                              | Kora (10 000 lamports)      | nothing                                   | `A3DNAnhwy5UX2spCgc28oi2ybWgPkThb6jLdyeyFEpxCRyECsr4C9c8GexR5hNP4YZEgEqGNqWZqp3wpnQHdwth`  |
| heir ATA create + `execute_token_rule` #1 + fee, through the paymaster :8081 | Kora (fee + 1 488 440 rent) | 0.50 USDC (account tier), from the payout | `3zvpXXFQ4s9yPvsfWqV2xYZ3JH8hpDZpESDUV8TowUtEVZ9nu9maeW3LYdmQZdxCG9guwb5zdMSZuR6v7SVaWoUY` |

- The heir received **1 960 000 lamports** (0.002 SOL minus the 2% fee configured at the time, the default again since 2026-10-08) and kept all of it; its SOL balance did not move during the USDC claim.
- The heir received **0.48 USDC**: 0.98 USDC net minus the 0.50 USDC fee, which Kora's payment ATA received.
- The treasury's test-mint ATA already existed, so Kora opened one ATA (`koraAtas=1`).

## JSON-RPC (verified against the running 2.0.5 nodes)

This section describes Kora itself (:8090-8093, with the key). Through the sponsor gateway (:8080) only `getPayerSigner`, `getBlockhash` and `signAndSendTransaction` exist, with the same shapes. The paymaster gateway (:8081) also has `estimateTransactionFee` (`transaction`, `fee_token`). Both gateways drop `signer_key` and `sig_verify`.

- Transport: HTTP POST, `Content-Type: application/json`, JSON-RPC 2.0.
- `params` is a named object with snake_case keys. Methods without parameters accept no `params` at all, or `{}` / `[]`.
- Errors come back as `{"jsonrpc":"2.0","error":{"code":-32000,"message":"Invalid transaction: …"},"id":1}`. A disabled method returns HTTP 405 with an empty body.
- `GET /liveness` returns 200. `GET /metrics` serves Prometheus metrics on the same port.

Transaction encoding:

- The transaction is base64 bincode `VersionedTransaction` (legacy or v0), including the signature array.
- The Kora signer must be account key 0 (the fee payer), with its signature slot left as 64 zero bytes.
- The user signatures must already be in place.
- The client sets the blockhash from `getBlockhash`. Kora only fills a blockhash when the signature array is empty.
- `sig_verify` defaults to `false`, which affects only Kora's simulation.

| Method                   | `params`                                                                            | `result`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| ------------------------ | ----------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `getConfig`              | —                                                                                   | `{fee_payers: [string], validation_config: {max_allowed_lamports, max_signatures, allowed_programs, allowed_tokens, allowed_spl_paid_tokens, disallowed_accounts, price_source, fee_payer_policy:{system:{…,nonce:{…}}, spl_token:{…}, token_2022:{…}}, price:{type:"free"} or {type:"fixed",amount,token,strict} or {type:"margin",margin}, token_2022:{blocked_mint_extensions, blocked_account_extensions}, allow_durable_transactions}, enabled_methods:{liveness, estimate_transaction_fee, get_supported_tokens, get_payer_signer, sign_transaction, sign_and_send_transaction, transfer_transaction, get_blockhash, get_config}}` |
| `getPayerSigner`         | —                                                                                   | `{signer_address: string, payment_address: string}`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `getBlockhash`           | —                                                                                   | `{blockhash: string}` (base58, commitment `confirmed`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `getSupportedTokens`     | —                                                                                   | `{tokens: [string]}`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `estimateTransactionFee` | `{transaction: string, fee_token?: string, signer_key?: string, sig_verify?: bool}` | `{fee_in_lamports: u64, fee_in_token: u64 or null, signer_pubkey: string, payment_address: string}`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `signTransaction`        | `{transaction: string, signer_key?: string, sig_verify?: bool}`                     | `{signed_transaction: string, signer_pubkey: string}` (no `signature` field in 2.0.5, although the website shows one)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `signAndSendTransaction` | `{transaction: string, signer_key?: string, sig_verify?: bool}`                     | `{signature: string, signed_transaction: string, signer_pubkey: string}`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |

Live examples:

```json
// sponsor  estimateTransactionFee {"transaction": "<pulse tx>"}
{
  "fee_in_lamports": 0,
  "fee_in_token": null,
  "signer_pubkey": "HCAeeSv4vBHGqWLEV7AdWK19xFYuosN76jwUGuoCs3pL",
  "payment_address": "HCAeeSv4vBHGqWLEV7AdWK19xFYuosN76jwUGuoCs3pL"
}
```

Client notes:

- Call `signAndSendTransaction` **once**. Calling `signTransaction` and then `signAndSendTransaction` uses two units of the usage limit.
- Sponsor: keep `(signatures × 5000) + CU limit × CU price / 1e6` at or below 50 000 lamports, with the CU limit at or below 60 000. For example, CU limit 20 000 at up to 2 000 000 µlamports. The app sets no ComputeBudget instructions today. `execute_sol_rule` uses about 18 000 CU (`compute_unit_profile`).
- Sponsored SOL claim: fee payer = the sponsor's `signer_address`, the heir signs, `execute_sol_rule(index)` / `release_vested_sol(index)` with executor = beneficiary = the heir, nothing else but ComputeBudget. Before sending, check that the net payout leaves a brand-new heir account rent-exempt (`getMinimumBalanceForRentExemption(0)`, 650 240 lamports on devnet today), or explain why it cannot be claimed yet. Rejections are `-32000` with readable messages; a sponsor that is down or rate-limited (`Rate limit: claimer … reached 12 sponsored claims per 24h`) means the heir pays its own fee or waits.
- Paymaster token claim: estimate without the payment (`estimateTransactionFee`, `fee_token` = USDC), append the payment from the heir's ATA (the claim's `beneficiary_token`) and sign once. The heir needs no USDC beforehand, but the net payout must cover the fee, or Kora's simulation fails.

## Funding and monitoring

- Balance: `solana balance HCAeeSv4vBHGqWLEV7AdWK19xFYuosN76jwUGuoCs3pL --url devnet`, or the `signer_balance_lamports` gauge at `http://127.0.0.1:8090/metrics` or `:8091`-`:8093/metrics` (refreshed every 30 s). All nodes spend from this one key. Each Kora-funded vault locks 0.0073 SOL until it is closed; each Kora-funded ATA spends 0.00204 SOL for good (covered by the account or plan price).
- USDC received: `spl-token balance --address BmGw5huqX9EaddNKjPHeC8Gp5yBkdPSScd1tejhMCJ4L --url devnet`
- Top up: `solana transfer HCAeeSv4vBHGqWLEV7AdWK19xFYuosN76jwUGuoCs3pL 0.5 --url devnet`
- Logs: `tail -f kora/logs/gateway.log` (one line per sponsored, paid or rejected transaction, prefixed `sponsor` or `paymaster`; paid lines show `tier=`), `kora/logs/sponsor.log` and `kora/logs/paymaster{,-account,-basic}.log`
- Usage counters:
  - Read: `docker exec deadman-kora-redis redis-cli -n 0 get kora:usage_limit:<wallet>`.
  - Reset: run `del` on the same key.

## Security notes

- `kora/.env` and `kora/*.json` are gitignored (`kora/.gitignore`) and created with mode 600. Never print the key.
- The fee payer is a hot key in an environment variable. Fund it only with what you can lose. On mainnet, use a remote signer.
- The sponsor cannot be made to transfer SOL or tokens, create accounts or approve delegates, and each transaction's fee is capped at 50 000 lamports.
- The API key never ships in the app; only the gateway holds it. The gateway's own policy (guard signature, vault guard binding, instruction allowlist, rate limits) is what protects the float, so keep 8090 closed at the firewall anyway.
- Kora's `/metrics` on :8090-8093 is not behind the API key (it shows the fee payer balance and request counts).
- The paymaster can be made to fund account rent, and only that: at most one vault and 2 ATAs per transaction (≤ 11.5M lamports), and only in a transaction that also pays that tier's price (3.00 USDC with a vault, 0.50 USDC with ATAs only). The ATAs must be ones the transaction pays into (a vault's, or a payout's beneficiary's or treasury's); the signer's own only as the beneficiary ATA of its own claim. A beneficiary can empty and close that ATA and keep its rent (1 488 440 lamports): that loses money for it below SOL ≈ $335, needs a real payable rule each time, and the ATA quota below bounds it. Kora-funded vaults are capped at 3 per owner and 20 in total per 24 h, and Kora-funded ATAs at 6 per owner and 100 in total. Vault rent returns to Kora on `close_vault` (the program pins `rent_payer`); ATA rent does not. Keep 8091-8093 closed at the firewall: with the key, Kora alone would accept a payment below the tier price in a `TEST_USDC_MINT` (Mock oracle), any instruction shape, and a cheap tier's node for a transaction that belongs in a dearer one.
- Residual risk: anyone can create vaults (rent is refundable on close) to get 24 pulses per day each. The global cap bounds that at about 0.1 SOL per day, but a determined attacker can use up the global cap and deny pulses to everyone else until the window rolls. The app then falls back to the guard paying its own fee (it holds 0.01 SOL from plan creation).
- Config gotcha: the sample `kora.toml` writes `[validation.token2022]`. Kora 2.0.5 deserializes `[validation.token_2022]` and silently ignores the other spelling.
- All `fee_payer_policy` sub-tables must list every field. In 2.0.5 an omitted sub-table defaults to all `false`.

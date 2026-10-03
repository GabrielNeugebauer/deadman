# Kora fee sponsor for Deadman (devnet)

Deadman runs one [Kora](https://github.com/solana-foundation/kora) 2.0.5 node, the **sponsor**, so that the phone's guard key never needs SOL:

| Node        | Port | Pricing | Purpose                                                             |
| ----------- | ---- | ------- | ------------------------------------------------------------------- |
| **sponsor** | 8080 | `free`  | Guard-key `pulse` and duress `lockdown`. Kora pays the network fee. |

Owners pay their own fees in SOL from their wallet; there is no token fee payment (product decision, 2026-10-03). The program still lets a separate account fund `create_vault` rent, so a paymaster can be added later without a program change.

- Program: `ACHVLMoLDM3YPpGbNST4cZW4Tf2jx6nzJGuusyLJHofL` (devnet)
- Fee payer / signer: `HCAeeSv4vBHGqWLEV7AdWK19xFYuosN76jwUGuoCs3pL`

```
 phone (Seeker)                      this machine                         devnet
 ─────────────                       ────────────                         ──────
 guard key  ── pulse/lockdown ──▶  sponsor :8080 ── simulate, validate, co-sign ──▶ RPC
 owner wallet ── everything else (pays its own SOL) ──────────────────────────────▶ RPC
                                        │
                                   Redis :6379 (localhost): per-wallet usage counters
```

## Files

| Path                                     | Purpose                                                                          |
| ---------------------------------------- | -------------------------------------------------------------------------------- |
| `kora/sponsor.toml`                      | Sponsor node config                                                              |
| `kora/signers.toml`                      | Signer pool: one memory signer, key read from `KORA_SIGNER_PRIVATE_KEY`          |
| `kora/.env`                              | **Gitignored.** `KORA_SIGNER_PRIVATE_KEY`, `RPC_URL`, optional `SPONSOR_API_KEY` |
| `kora/fee-payer.json`                    | **Gitignored.** Keypair file for the fee payer                                   |
| `kora/logs/*.log`, `kora/*.pid`          | Runtime files (gitignored)                                                       |
| `scripts/kora_start.sh` / `kora_stop.sh` | Start or stop Redis and the sponsor                                              |

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
scripts/kora_start.sh        # starts the Redis container and the sponsor on :8080; idempotent
scripts/kora_stop.sh         # stops the sponsor
scripts/kora_stop.sh --all   # also stops Redis (counters persist in the `deadman-kora-redis` volume)
```

- Kora 2.0.5 always binds `0.0.0.0` (hard-coded in `run_rpc_server`). Only `--port` is configurable. The script prints the LAN URLs. Phones must be on the same Wi-Fi, and the host firewall must allow TCP 8080.
- CLI shape: `kora --config <toml> --rpc-url <url> rpc start --signers-config <toml> --port <n>`. The global flags come before `rpc`, and `RPC_URL` is also read from the environment.
- `KORA_API_KEY` and `KORA_HMAC_SECRET` in the environment override `[kora.auth]`. The start script clears both and sets them from `SPONSOR_API_KEY` when present. Clients then send the `x-api-key` header.
- Check a config: `kora --config kora/sponsor.toml --rpc-url $RPC_URL config validate-with-rpc --signers-config kora/signers.toml`

## Node policies

- Only allowlisted programs may appear in **any** instruction. Kora simulates the transaction (`innerInstructions: true`) and checks CPIs too.
- The fee payer policy denies everything: no SOL transfer, assign, allocate or nonce use, and no SPL/Token-2022 transfer, approve, burn, close, set-authority, mint, init or freeze.
- `transfer_transaction` is disabled. It would let callers make the fee payer create ATAs. Disabled methods return HTTP 405 with an empty body.
- `allow_durable_transactions = false`.
- `rate_limit = 20`: a global requests-per-second cap for the node, not per wallet.
- Per-wallet usage limit (`[kora.usage_limit]`) through Redis. The key is `kora:usage_limit:<wallet>`, where the wallet is the first signer that is not Kora. It is a **lifetime** counter with no time window. It counts every `signTransaction` / `signAndSendTransaction` call, including rejected ones. It fails closed if Redis is down.

### sponsor (8080)

- `allowed_programs`: Deadman and Compute Budget only.
- `max_allowed_lamports = 50_000`. This caps the network fee: two signatures (10 000) plus at most 40 000 lamports of priority fee. Fee payer outflow must also be at most 50 000, but every outflow path is already blocked.
- `max_signatures = 2` (Kora plus the guard).
- Usage limit: 1 000 signs per guard key (Redis DB 0).
- Kora cannot filter by instruction discriminator, so any Deadman instruction that needs no other program gets a free fee here (for example `update_policy` signed by the owner). These calls cost at most 50 000 lamports and need a real vault, which costs rent to create. `create_vault` and token rules fail, because their CPIs hit System or Token, which are not allowlisted. Verified: `Program 11111111111111111111111111111111 is not in the allowed list`.
- `allowed_tokens` must be non-empty or Kora will not start, so it lists devnet USDC. Nothing is accepted as payment, and `estimateTransactionFee` with `fee_token` errors with `Token … is not supported`.

## Verified live against devnet

| Test                                           | Result                                                                |
| ---------------------------------------------- | --------------------------------------------------------------------- |
| guard `pulse` through `signAndSendTransaction` | landed, fee paid by Kora (sig `5xUxL1TS…C7Db`)                        |
| `pulse` signed by a stranger                   | rejected in simulation (`custom program error: 0x1770`, Unauthorized) |
| `create_vault`                                 | `Program 1111… is not in the allowed list`                            |
| 200k CU × 1 000 000 µlamports priority fee     | `Fee 205000 exceeds maximum allowed 50000`                            |

## Adding a token paymaster later

Kora simulates transactions with inner instructions, so rent a program pays from the fee payer through a CPI (our `create_vault` with `payer` = Kora) counts as fee-payer outflow: it needs `fee_payer_policy.system.allow_create_account = true`, must fit under `max_allowed_lamports` (a vault is ~5.7M lamports of rent), and is billed under `margin` pricing. On mainnet use `margin` with `price_source = "Jupiter"` (needs `JUPITER_API_KEY`); Jupiter has no devnet prices, and the `Mock` source misprices devnet USDC.

## JSON-RPC (verified against the running 2.0.5 nodes)

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
- Sponsor: keep `(signatures × 5000) + CU limit × CU price / 1e6` at or below 50 000 lamports. For example, CU limit 20 000 at up to 2 000 000 µlamports.

## Funding and monitoring

- Balance: `solana balance HCAeeSv4vBHGqWLEV7AdWK19xFYuosN76jwUGuoCs3pL --url devnet`, or the `signer_balance_lamports` gauge at `http://<host>:8080/metrics` (refreshed every 30 s).
- Top up: `solana transfer HCAeeSv4vBHGqWLEV7AdWK19xFYuosN76jwUGuoCs3pL 0.5 --url devnet`
- Logs: `tail -f kora/logs/sponsor.log`
- Usage counters:
  - Read: `docker exec deadman-kora-redis redis-cli -n 0 get kora:usage_limit:<wallet>`.
  - Reset: run `del` on the same key.

## Security notes

- `kora/.env` and `kora/*.json` are gitignored (`kora/.gitignore`) and created with mode 600. Never print the key.
- The fee payer is a hot key in an environment variable. Fund it only with what you can lose. On mainnet, use a remote signer.
- The sponsor cannot be made to transfer SOL or tokens, create accounts or approve delegates, and each transaction's fee is capped at 50 000 lamports.
- No auth on devnet, because an API key shipped in a mobile app can be extracted. On mainnet, put a backend in front that holds the HMAC secret, or rely on the usage limits and pricing.
- Config gotcha: the sample `kora.toml` writes `[validation.token2022]`. Kora 2.0.5 deserializes `[validation.token_2022]` and silently ignores the other spelling.
- All `fee_payer_policy` sub-tables must list every field. In 2.0.5 an omitted sub-table defaults to all `false`.

> Research report produced 2026-10-02 while building the rail. Sources are linked inline.

# CloakRoute report: Cloak payout rail (Deadman, 2026-10-02)

`CloakRoute` is built and `available` is true on mainnet once the JS runtime is running. A real Chromium run took the deposit pipeline from start to the point just before signing, without touching any funds. `dart analyze lib/rails test/rails` is clean and all 19 tests in `test/rails/cloak_route_test.dart` pass with mocks and no network. No real deposit has been made yet, so the first mainnet run is still unproven.

## 1. Verified facts

- **Program id:** `zh1eLd6rSphLejbFfJEneUwzHRfMKxgzrgkfwA6qRkW`, live since 2026-08-24. Upgrades go through a Squads 3-of-4 multisig with a 1-hour delay. Sources: https://docs.cloak.ag/releases/latest and the README in the `@cloak.dev/sdk@0.2.5` npm tarball. I checked it with `getAccountInfo`: it is executable on mainnet.
- **Devnet:** there is no deployment. `getAccountInfo` on `api.devnet.solana.com` returns `null`. Devnet needs your own deployment plus a rebuilt SDK, because the relay address is fixed inside the published SDK (README, "Devnet and local").
- **A deposit needs a ZK proof, not just a commitment.** Deposit, transfer and withdraw are all the same `Transact` instruction: a Groth16 proof, 2 inputs and 2 outputs, 42,672 constraints. Sources: https://docs.cloak.ag/sdk/shielded-transfers and `transact()` in `dist/index.js`, which calls `snarkjs.groth16.fullProve` even when depositing.
- **Deposits also need the relay.** The program requires a signed risk quote from `<relay>/range-quote`. The relay also registers a viewing key (`nk`) once per wallet. That step is on by default; turning it off is not a no-relay mode.
- **Proving files:** 19.6 MB `.zkey` and 3.2 MB `.wasm`, served from `storage.googleapis.com/cloak-circuits/circuits/0.2.0`. Their SHA-256 hashes are pinned in the SDK. CORS is open (`*`).
- **Sending to someone else privately works, but it is not an address in the usual sense.**
  - The recipient shares two keys: a UTXO public key (a number in the proof system's field) and an X25519 viewing public key.
  - `transfer(...)` with `recipientViewingPublicKey` puts a sealed envelope on chain that only the recipient can find, using `scanRecipientDeliveryNotes`.
  - Cloak defines no string format for this pair. Its first-party app does not expose receiving these transfers; it uses payment links instead. Source: https://docs.cloak.ag/sdk/shielded-transfers
  - "Private send" to a normal Solana address is a withdrawal from the pool. Source: https://docs.cloak.ag/guide/private-send
- **Relay / REST API:** `https://api.cloak.ag`, fixed inside the SDK. It submits sends and withdrawals (the sender pays no gas), serves risk quotes, commitments and viewing-key registration, and its CORS is `*` (checked with OPTIONS). It does not generate proofs; that always happens on the device.
- **Fees:**
  - Deposits and private sends: no protocol fee.
  - Withdrawals and swaps: 0.3% plus 0.005 SOL or 0.45 USDC/USDT.
  - Minimum deposit: 0.01 SOL or 1 USDC/USDT.
  - Sources: https://www.cloak.ag/, https://docs.cloak.ag/releases/latest
- **The Rust crate `cloak-sdk` is a different project.** It is a stealth-address library from github.com/CloakSDK/cloak-sdk with no link to cloak.ag. Source: https://docs.rs/cloak-sdk

## 2. Approach chosen: option 3, the TS SDK in a headless WebView

- **Option 1 (pure Dart) is not possible.** Every deposit needs a Groth16 proof, plus the relay risk quote and viewing-key protocol, and no Dart prover exists.
- **Option 2 (REST relayer) does not exist** in the form needed: the relay never generates proofs.
- **Option 3 works.** I bundled `@cloak.dev/sdk@0.2.5` with esbuild into `assets/cloak/cloak.js` (3.5 MB). A full pipeline run in headless Chrome 154 used a random unfunded key and the `dryRunDeposit` operation. It downloaded the proving files, checked their hashes, built the witness, generated the Groth16 proof in about 5.6 s on desktop, got a real risk quote from `api.cloak.ag`, built the transaction, and stopped before signing. Nothing was signed, sent or registered.
- **Flutter package:** `flutter_inappwebview: ^6.1.5`, using `HeadlessInAppWebView` and `callAsyncJavaScript`. The QuickJS-based `flutter_js` cannot do this because it has no WebAssembly. `webview_flutter` has no headless mode or async return values.

## 3. Real vs. stubbed

**Real:**
- `lib/rails/cloak_route.dart`:
  - `CloakRoute` with `available` and `unavailableReason`. It is false off mainnet, and false when no runtime has been started.
  - Quoting for SOL, USDC and USDT, enforcing the pool minimums and keeping 0.005 SOL on the claim key for fees.
  - Two destination formats:
    - `cloak:<64-hex utxo pubkey>:<64-hex viewing key>`, a format I defined for Deadman: a shielded transfer with no protocol fee.
    - A plain Solana address: a private send. The quote shows the amount after the exit fee.
  - `execute` (balance check, then the JS call), and `status` via `getSignatureStatuses`.
  - `receiveAddress(spendKey)` derives a Cloak address on the device.
  - `CallAsyncCloakRuntime` adapter for the WebView.
- **Bundle bridge** (`tool/cloak_bundle/src/entry.mjs`), operations `shieldAndSend`, `receiveAddress`, `dryRunDeposit` and `ping`:
  - The claim key's Cloak identity and the deposit note are derived deterministically from (claim seed, mint, amount).
  - A re-run after a crash looks up the deposit commitment through the relay and skips depositing again. If the note is already spent it returns `already-sent`.
  - I checked that the bundle's key derivation matches the unbundled SDK byte for byte.
- **Build:** `tool/cloak_bundle/` (`package.json` with exact versions, `package-lock.json`, `build.mjs`; run `npm ci && node build.mjs`). The WebView host page is `assets/cloak/index.html`, with a strict content security policy.

**Not wired yet:**
- `tool/cloak_bundle/cloak_webview_runtime.dart.example` is a ready WebView host. It is kept as `.example` because the package isn't in `pubspec.yaml` yet; once it is, move it to `lib/rails/cloak_webview_runtime.dart`. It must run in the foreground isolate (the claim screen), not from workmanager.

**Not built:**
- **Beneficiary-side scanning and unshielding of `cloak:` payouts.** Cloak's own app cannot receive shielded transfers, so a `cloak:` payout is only usable once Deadman adds `scanRecipientDeliveryNotes` and `fullWithdraw` operations, plus note storage. I estimate 1–2 days. Within the 6-day window, the Solana-address (private send) mode is the one a beneficiary can use without that work.
- **Not verified yet:**
  - The SOL fee reserve (0.005 SOL) and the SPL reserve (0.01 SOL) are estimates; no real deposit has been made.
  - Whether an SPL withdrawal creates the recipient's token account if it doesn't exist.
  - Proof time on the Seeker phone.

## 4. Privacy analysis

- **What is still public:**
  - Vault to claim key (amount, time).
  - Claim key to Cloak pool: the deposit amount, which is the payout minus the reserve, is visible and linkable to the vault.
- **What is hidden:**
  - A shielded transfer shows only nullifiers, commitments and a zero public amount.
  - In private-send mode, the withdrawal to the beneficiary's wallet is linked to the deposit only by amount and timing. Doing it right after the deposit with a near-identical amount is weak privacy; adding a delay or splitting amounts would help.
- **What Cloak itself sees:**
  - Registering the viewing key is mandatory. The relay therefore holds the claim identity's `nk` and can read its notes, including the amount and the recipient's Cloak public key or address. Cloak, as the compliance operator, can link vault, claim key and beneficiary.
  - Range screens the claim key, and the relay sees the device's IP address.
- **Secrets:**
  - The 32-byte claim seed is passed only into the on-device WebView. The SDK sends proofs, public keys and signatures, never keys.
  - The relay and proving-file locations are fixed inside the SDK, and the page only loads its own scripts.
  - One residual risk: a base64 copy of the seed exists briefly as a Dart `String`, which cannot be wiped.
- **No clawback:** a shielded transfer to a wrong `cloak:` address is stranded for good. A deposit that landed before a failed second step stays recoverable from the claim key by re-running.

## 5. Packages and assets for the lead to add

- `pubspec.yaml`:
  - `flutter_inappwebview: ^6.1.5` (latest release is from 2024-10; check it builds with the current Flutter and Android Gradle versions).
  - Under `flutter: assets:`, add `- assets/cloak/`.
- Optional: ship the 23 MB proving files in the APK to avoid downloading them each session. It needs a small fetch override in the page; the hash check still applies.
- Wiring: `CloakRoute(runtime: await CloakWebViewRuntime.start())`. Use `AppConfig.cluster='mainnet-beta'` with an RPC that allows browser requests; `api.mainnet-beta.solana.com` returned 403 from the browser, `solana-rpc.publicnode.com` worked.
- For USDC/USDT payouts, the vault program must also send the claim key about 0.01 SOL for fees.
- Add `tool/cloak_bundle/node_modules/` to `.gitignore`; I already added a `.gitignore` inside that folder.

Files are in /home/gabriel/Documentos/Deadman/deadman:
- lib/rails/cloak_route.dart
- test/rails/cloak_route_test.dart
- assets/cloak/cloak.js (sha256 `9313d2bf…4c99`)
- assets/cloak/index.html
- tool/cloak_bundle/{package.json, package-lock.json, build.mjs, src/entry.mjs, src/shims.mjs, src/empty.mjs, cloak_webview_runtime.dart.example, .gitignore}

# Deadman on-chain audit (2026-10-05)

Scope: Anchor program `onchain/programs/deadman` (program id `ACHVLMoLDM3YPpGbNST4cZW4Tf2jx6nzJGuusyLJHofL`, Anchor 1.1.2, 21 instructions), at the working tree of `feat/safety-net-mvp-02-10-2026` (program sources last changed in `12906e3`).
The off-chain code (Kora gateway, paymaster tiers, CORS, Cloak/Zcash rails, web wallet bridge) is in `offchain.md`. This file covers only what the program enforces.

Method: the solana-ai-kit `/audit-solana` checklist (owner, signer, PDAs, type confusion, duplicate mutable accounts, remaining_accounts, arithmetic, CPI, Token/Token-2022, lifecycle, close/revival, economics, CU). The fixes claimed in `docs/security-audit-2026-10-03.md` and `docs/security-review-2026-10-04.md` were re-checked against the current code. The audit was read-only: PoCs ran in a scratch copy of the workspace outside the repo.

## Summary

| Severity | Count |
| -------- | ----- |
| Critical | 0     |
| High     | 0     |
| Medium   | 0     |
| Low      | 7     |
| Info     | 9     |

No path was found that lets an executor, beneficiary, guard, guardian, sponsor or third party take value they are not owed, or change a plan's authorities. The new code (installment vesting, the per-rule stipend bitmask, `rent_paid`, the account-wide subscription with its fee waiver, and `recover_legacy_vault`) is validated correctly.

Of the 7 Lows, two are new:

- **L-1:** the stipend bitmask is not remapped when `update_policy` compacts the tiers or restarts a plan. A later private-rail heir can be denied gas. A PoC confirms it.
- **L-2:** `recover_legacy_vault` pays every lamport to the owner. It ignores `rent_payer`, vesting commitments and lockdown. It is harmless on devnet today, but becomes a drain if the `Vault` size ever changes again.

The other five Lows are open items carried over from earlier audits.

## Instruction map

Funds-moving or authority-changing instructions are marked ★. These were reviewed first.

| Instruction              | Signers                            | Key accounts and validation                                                                                                                        | Effect                                                                             |
| ------------------------ | ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| ★ `init_config`          | admin                              | `config` init `[config]`; `program.programdata_address() == program_data`; `program_data.upgrade_authority == admin`                               | Sets the admin, treasury and fees (each fee ≤ 500 bps)                             |
| ★ `set_config`           | admin                              | `config` seeds + bump, `has_one = admin`                                                                                                           | Changes treasury and fees                                                          |
| ★ `set_subscription`     | admin                              | `config has_one admin`; `sub_config` init_if_needed `[sub_config]`                                                                                 | Sets the subscription price, period, mint, enabled flag and min_periods            |
| ★ `subscribe`            | owner, payer                       | `subscription` init_if_needed `[sub, owner]`; `mint == sub_config.mint`; `owner_token` authority = owner; `treasury_token` = ATA(config.treasury)  | Moves USDC from owner to treasury and extends `paid_until`                         |
| ★ `create_vault`         | owner, payer                       | `vault` init `[vault, owner, plan_id]`; guard ≠ owner/default; `apply_policy`                                                                      | New inheritance plan; records `rent_payer` and `rent_paid`                         |
| ★ `create_vesting`       | owner, payer                       | same as `create_vault` plus `apply_vesting`                                                                                                        | New vesting plan                                                                   |
| ★ `update_policy`        | owner                              | `OwnerAction`: seeds from `owner.key()`, `has_one owner`; Inheritance only; unlocked                                                               | Replaces pending tiers (paid and skipped tiers stay as history); sets the guardian |
| ★ `set_guard`            | owner                              | `OwnerAction`; allowed during lockdown                                                                                                             | Rotates the guard key                                                              |
| ★ `revoke_vesting`       | owner                              | `OwnerAction`; Vesting only; unlocked; revocable; not yet revoked                                                                                  | Stops future vesting                                                               |
| `pulse`                  | owner or guard                     | seeds from the stored owner/plan_id; signer ∈ {owner, guard}; Inheritance only; not completed                                                      | Check-in; guard limited by `check_guard_pulse`                                     |
| `lockdown`               | owner, guard or guardian           | signer ∈ {owner, guard, guardian}; guardian rate-limited                                                                                           | Freezes withdraw, policy and close                                                 |
| `unlock`                 | owner + guardian                   | `has_one owner`; guardian == stored guardian                                                                                                       | Ends the lockdown early                                                            |
| ★ `close_vault`          | owner                              | `has_one owner`, `has_one rent_payer`, `close = rent_payer`; unlocked; vesting fully released                                                      | Excess to owner, `rent_paid` to rent payer                                         |
| ★ `withdraw_sol`         | owner                              | `has_one owner`; unlocked; ≤ withdrawable − committed                                                                                              | Moves SOL to owner                                                                 |
| ★ `withdraw_token`       | owner                              | `has_one owner`; vault ATA; `owner_token` authority = owner; ≤ balance − committed                                                                 | Token CPI signed by the vault PDA (+ remaining_accounts)                           |
| ★ `execute_sol_rule`     | anyone                             | `beneficiary == rule.beneficiary`; `treasury == config.treasury`; `subscription` = owner's sub PDA                                                 | Pays a due SOL tier                                                                |
| ★ `execute_token_rule`   | anyone (+ beneficiary to redirect) | mint == rule.mint; vault ATA; `beneficiary_token` = canonical ATA unless the beneficiary signs; `treasury_token` authority = treasury              | Pays a due token tier + rail stipend                                               |
| `skip_rule`              | anyone                             | Inheritance; pending, in order, due + grace; token tiers need the vault ATA (address-derived)                                                      | Reserves the tier's share and lets later tiers run                                 |
| ★ `release_vested_sol`   | anyone                             | `ExecuteSolRule` accounts; Vesting; mint None                                                                                                      | Pays vested − released                                                             |
| ★ `release_vested_token` | anyone (+ beneficiary to redirect) | `ExecuteTokenRule` accounts; Vesting                                                                                                               | Pays vested − released + stipend                                                   |
| ★ `recover_legacy_vault` | owner                              | `legacy` owned by the program at `[vault, owner, plan_id]` (canonical bump); size ≠ `Vault::SPACE`; discriminator, owner and plan_id bytes checked | Drains every lamport to the owner and frees the account                            |

## Findings

### L-1 [Low] Stipend bitmask is indexed by rule position but never remapped or cleared, so after `update_policy` a new private-rail tier can be denied its gas stipend (NEW, PoC confirmed)

- **Where:**
  - `state.rs:228` (`stipend_paid: u8`)
  - `funds.rs:51-55,64` (`bit = 1 << index`; skipped if already set)
  - `state.rs:540-548,591-605` (`apply_policy` compacts the history to the front, or empties it once the plan has completed, and never touches `stipend_paid`)
- **Instruction:** `update_policy`, then `execute_token_rule`.
- **Scenario A (plan restart):**
  1. Tier 0 is a Cloak USDC tier to claim key C. It pays and receives the 0.012 SOL stipend, so bit 0 is set.
  2. Every tier has now paid. The owner calls `update_policy` with a new Cloak USDC tier to claim key D, which lands at index 0.
  3. Once it is due, anyone runs `execute_token_rule(0)`. D receives the tokens but 0 lamports, even though the vault holds spare SOL: bit 0 is still set.
- **Scenario B (index shift):**
  1. The rules are `[0: SOL tier to A (pending), 1: Cloak USDC to C]`. Tier 1 pays and sets bit 1.
  2. The owner returns and replaces the pending tiers. History `[C]` moves to index 0, and the new Cloak tier to D lands at index 1, whose bit is already set.
  3. D gets no stipend.
- **Impact:** A private-rail claim key receives tokens but no SOL to route them. The beneficiary has to fund the claim key from another wallet, which defeats the privacy of the rail, or use a sponsor. The direction is denial only: a set bit always belongs to a tier that already executed, so no tier can be paid twice.
- **PoC:** `poc_stipend_bit_survives_plan_restart` and `poc_stipend_bit_shifts_with_history` (scratch copy of `tests/test_deadman.rs`, both pass and assert `lamports(D) == 0`).
- **Fix:** In `apply_policy`, rebuild `stipend_paid` from the kept history: for each kept rule `j` that came from old index `i`, copy bit `i` to bit `j`, and clear all other bits. On a full restart, set `stipend_paid = 0`. Alternatively, store a `stipend_paid: bool` inside each `Rule`. The 55-byte `_reserved` region cannot be used for this, because `Rule` is inside the `Vec`, so the bitmask remap is the cheaper fix.

### L-2 [Low] `recover_legacy_vault` sends every lamport to the owner and ignores `rent_payer`, vesting commitments, reserved skipped shares and lockdown (NEW)

- **Where:** `vault.rs:389-411`.
- **Instruction:** `recover_legacy_vault`.
- **Scenario:** The only check is `data[8..40] == owner` on any program-owned account at `[vault, owner, plan_id]` whose size differs from `Vault::SPACE`. The intermediate layout from `0c91602` already had `kind = Vesting` and `rent_payer`, but no `rent_paid`. A plan in that layout could be Kora-sponsored and could be a non-revocable vesting plan. After the size change, its owner calls `recover_legacy_vault(plan_id)` and receives:
  - the sponsor's rent, and
  - all SOL committed to vesting beneficiaries.

  A locked-down legacy plan can also be drained by an owner-key holder, because the lockdown is not checked. The same applies to every current plan if a future upgrade changes `Vault::SPACE` again.

- **Current exposure:** None. `getProgramAccounts` on devnet (2026-10-05) shows 15 accounts at the current 1390 bytes and only two legacy vaults:
  - 958 bytes (`zkzYY…f5vs`), a pre-`plan_id` layout;
  - 996 bytes (`6gdBWNmcJvRyuUZHnipwiTx8ucN6yjMFGwaYJkyzPYUB`), with no `rent_payer` and no vesting.

  No account in the `0c91602` layout exists. The finding is latent and depends on a future layout change. The layout note in `state.rs:177-181` promises that the size will stay fixed.

- **Fix:**
  - Gate the instruction to the known legacy sizes (`data_len ∈ {958, 996, …}`), or
  - remove it once devnet is migrated, and
  - add a test that fails if `Vault::SPACE` changes.

  If it is kept for future layouts, decode `rent_payer`, `rent_paid` and the vesting fields per layout, return the rent to the payer, and refuse while anything is committed or locked.

### L-3 [Low] Underfunded vesting plans pay first-come; the release order is chosen by any executor (carried: 2026-10-04 L-3, still open)

- **Where:** `funds.rs:488-489` (`due.min(withdrawable)`), `funds.rs:561-562` (`due.min(vault_token.amount)`), and `vault.rs:305-347` (no funding requirement).
- **Scenario:** A plan owes Alice and Bob 1 SOL each, but holds 1 SOL. Any executor releases Alice first, and she takes everything vested. Bob gets nothing until more SOL arrives. Installments make this more frequent, because every installment is a new race.
- **Fix:** Release pro-rata when `committed(mint) > balance` (`due * balance / committed`), or require full funding at creation and before a release.

### L-4 [Low] Vesting guarantee does not hold for mints the owner controls (Token-2022 permanent delegate, freeze authority) (carried: 2026-10-04 L-4, still open)

- **Where:** `state.rs:333-351` (`apply_vesting` accepts any mint); `funds.rs:303-311` (Token-2022 accepted).
- **Scenario:**
  - An owner who is the permanent delegate of the vested mint transfers the "committed" tokens out of the vault ATA.
  - A freeze authority freezes the vault ATA and blocks every release.

  In both cases `committed()` still shows the tokens as owed.

- **Fix:** In `release_vested_token` (or `create_vesting` when the mint is passed), reject Token-2022 mints that have `PermanentDelegate`. In the client, flag plans whose mint has a freeze authority.

### L-5 [Low] Token-2022 transfer-fee mints: `rule.paid` and `RuleExecuted.amount` overstate what the beneficiary received, and the treasury fee is taxed again (carried: 2026-10-03 L-5, still open)

- **Where:** `funds.rs:400-401`, `funds.rs:617-621` (`paid += net`).
- **Fix:** Record the amount actually received (the destination balance before and after), or document that `paid` is measured before the mint's fee.

### L-6 [Low] The private-rail SOL stipend is taken from SOL that pending inheritance SOL tiers would receive, so the executor's choice of order decides who gets it (carried: 2026-10-03 L-4, partly mitigated)

- **Where:** `funds.rs:58-60`. Spare SOL = withdrawable − committed − reserved for skipped SOL tiers. For inheritance, `committed` is 0.
- **Status:** The stipend is now paid at most once per rule (bitmask) and never from vesting commitments or skipped-tier reserves. A pending SOL tier, for example "100% of SOL to Bob", can still lose up to 8 × 0.012 SOL to token tiers that execute first. The stipend is also not reported in `RuleExecuted`.
- **Fix:** Subtract the stipends of pending private token tiers from the SOL available to SOL tiers, or fund stipends from a dedicated reserve. Add a `stipend` field to the event.

### L-7 [Low] `close_vault` ignores token balances and pending tiers (carried: 2026-10-03 L-6, still open)

- **Where:** `vault.rs:277-298`.
- **Scenario:** Tokens in the vault ATAs can only be reached again by recreating the same `plan_id`. The recreated plan silently adopts them. For vesting plans, the close is correctly refused while anything is owed.
- **Fix:** Require the vault ATAs passed in `remaining_accounts` to be empty, or document this and have the client sweep tokens before closing.

## Info

- **I-1 Pre-`plan_id` devnet vault is unrecoverable.** `zkzYYoAskiTUzBNTHhYUBAxh3rpuStpyLKpZbCvf5vs` (958 bytes, 5,516,880 lamports, owner `AppAYe7k…9PbA`) lives at `[vault, owner]` with no `plan_id` seed. `recover_legacy_vault` derives `[vault, owner, plan_id]`, so it can never match this account, and no other instruction can read it. The amount is small and on devnet only. The 996-byte vault is at `plan_id` 0 and can be recovered.
- **I-2 Vesting fee waiver is evaluated at release time** (`state.rs:80-86`). Amounts that vested while the owner's subscription was active pay the full fee if they are released after it lapses. A beneficiary can avoid this by releasing before the lapse. A protocol keeper should not deliberately delay releases.
- **I-3 Treasury coupling.**
  - `execute_token_rule` and `release_vested_token` require a `treasury_token` account even when the fee is 0 because of the subscription waiver (`funds.rs:324-330`). An heir may have to create the treasury ATA first.
  - A beneficiary equal to `config.treasury` still hits Anchor's duplicate-mutable check when both use the treasury ATA (prior ACCT-8).
- **I-4 Admin powers.** One admin key, set at `init_config`, with no rotation instruction (`config.rs` `SetConfig`). Fee changes (≤ 5%) and treasury changes apply at once to every existing plan, including those of deceased owners. Recommend a multisig and a timelock before mainnet.
- **I-5 `set_guard` during lockdown** (`vault.rs:129-141`): this is by design (it defeats a stolen guard key), but it also lets an owner-key thief strip the device's ability to re-lock (prior L-3). Document it.
- **I-6 `guardian_ready_at` is not reset when the guardian changes** (`state.rs:590`, `vault.rs:210`), so a new guardian inherits the old guardian's cooldown (prior SM-4).
- **I-7 Skipped tiers stay claimable after the owner returns** (`state.rs:489`). A tier skipped with `reserved = 0` (empty balance at skip time) competes with later tiers for deposits that arrive afterwards. This is consistent with the "already due" semantics, but it is not obvious to users.
- **I-8 No residual or sweep path** for assets left over after the last tier (prior SM-7).
- **I-9 Strict clippy hits** in program code: 2, neither exploitable.
  - `funds.rs:94`: `4 + extra.len()`
  - `state.rs:568`: `rules[i - 1]`, guarded by `i == 0 ||`
  - `rules.len() as u8` casts (max 8)

  There is no `unwrap`, `expect` or `panic` in program code.

## Needs verification

1. **Token-2022 transfer-hook privilege de-escalation** (prior FUNDS-7). `vault_transfer` (`funds.rs:72-110`) forwards executor-supplied `remaining_accounts` with `is_signer = false`. It relies on Token-2022 and the transfer-hook interface de-escalating any extra meta that names the vault PDA as a signer. This was not proven with a malicious hook program. The mint is pinned to an owner-chosen `rule.mint`, so an attacker would need the owner to name a malicious hook mint.
2. **Deployed devnet binary matches this source.** 15 accounts at 1390 bytes show that the current layout is deployed. `anchor build --verifiable` was not run, because it needs Docker.
3. **No other cluster holds vaults in the `0c91602` layout** (rent_payer, no rent_paid; see L-2). Devnet was checked and has none.

## Re-verified fixes from earlier audits

- **2026-10-03 H-1** (stuck token tier blocks later tiers): fixed.
  - `skip_rule` reserves the share (`funds.rs:434-469`, `state.rs:471-478`).
  - A non-ATA destination requires the beneficiary's signature (`funds.rs:362-365,556-559`).
- **M-1** (guard can delay forever): fixed. `check_guard_pulse` enforces a 365-day window from `owner_last_seen` and blocks after any release or skip (`state.rs:410-423`).
- **M-3** (keeper pays rent for empty tiers): fixed. There is no `init_if_needed` in payouts, and `NothingToPay` is enforced.
- **L-1** (tier consumed with 0 paid): fixed by `NothingToPay` and `BeneficiaryCannotReceive`.
- **L-2** (edit re-arms paid tiers): fixed. History is kept (`state.rs:540-548`).
- **FUNDS-8** (vault as its own beneficiary): rejected in both `apply_policy` and `apply_vesting`.
- **NEW-1, NEW-2, NEW-3** hold:
  - skips reserve the share;
  - later tiers see the balance minus reserved shares;
  - redirecting a payout needs the beneficiary's signature.
- **2026-10-04 L-2** (rent recomputed from the sysvar): fixed.
  - `rent_paid` is stored.
  - `rent_reserve = max(min_balance, rent_paid)`.
  - `close_vault` returns exactly `rent_paid` to `rent_payer` and the excess to the owner.
  - Tests cover a rent cut and a rent rise.
- **2026-10-04 L-1** (legacy layouts): partly addressed by `recover_legacy_vault` (see L-2 and I-1).

## Checked and clean (new code)

- **Subscription fee waiver:**
  - `Subscription::load` (`state.rs:60-76`) requires the canonical `[sub, vault.owner]` PDA whether or not it exists. The executor cannot drop the waiver, and another owner's subscription cannot be borrowed (tests `payouts_reject_a_substituted_subscription_account` and `another_owners_plan_is_not_covered…`).
  - A created account is deserialized with its discriminator checked, its stored owner is matched, and its key is re-derived from the stored canonical bump.
  - Seeds `sub`+32 bytes and `sub_config` cannot collide with each other or with `config` or `vault`+34 bytes, because their lengths differ.
- **`subscribe`:**
  - The owner must sign, so nobody can create or extend someone else's subscription.
  - The mint is pinned to `sub_config.mint` and owned by `token_program`.
  - `treasury_token` is the treasury's canonical ATA.
  - `transfer_checked` goes through `token_interface`.
  - `price × periods` and `period × periods` use checked math.
  - `min_periods` is enforced when the subscription is new or has lapsed.
  - The `init_if_needed` re-entry rewrites only `owner` (same key), `bump` (canonical) and `paid_until` (monotonic).
- **`set_subscription`:** admin only (`has_one admin` on the config PDA); bounds checked.
- **Installment vesting (`state.rs:254-282`):**
  - Values are floored to whole periods with checked div/mul, then `u128` math.
  - The result is monotonic in time, and the cliff is checked first.
  - At `duration` the full total vests.
  - Revocation caps vesting at `vested(revoked_at)`, so only whole installments are kept.
  - The period is validated to be 0, or between 60 s and the shortest schedule.
- **Stipend once per rule:**
  - `checked_shl` with index < 8.
  - Paid only when the claim key holds less than the stipend and only from SOL that is not committed or reserved.
  - The stipend exceeds the 0-byte rent minimum.
  - Repeat payments are impossible (but see L-1).
- **`recover_legacy_vault` access control:**
  - Program ownership, the canonical PDA from the caller's own key, `size != SPACE`, the discriminator, the plan_id bytes and the owner bytes are all checked.
  - The account is drained, assigned to System and resized to 0, so it cannot be revived as program state.
  - The program_autofixer reported no issues.
- **Duplicate mutable accounts** (Anchor 1.1.2 checks `Account` and `InterfaceAccount` only):
  - `vault`, `vault_token`, `beneficiary_token` and `treasury_token` cannot alias.
  - The `UncheckedAccount` lamport destinations (beneficiary, treasury, rent_payer) are only ever credited.
  - `owner == rent_payer` on close is handled.
- **CPI:**
  - `token_program` is `Interface<TokenInterface>`, so only Token or Token-2022.
  - The vault PDA seeds are passed only to that program.
  - Vault state is not re-read from a stale copy after a CPI; lamports are read live.
  - Re-entry into Deadman from a hook is blocked by the runtime.
- **Arithmetic:** every amount uses checked or `u128` math with `try_from` narrowing. Fees round down (in the beneficiary's favour, less than 1 base unit per payout).
- **Lifecycle:**
  - `init_config` is gated on the upgrade authority.
  - Vault `init` is keyed by the owner signer, so it cannot be squatted.
  - A pre-funded PDA is handled by Anchor.
  - `close` zeroes the account and drains it to `rent_payer`.

## Tests run

- `cd onchain && cargo test`: 70 integration tests (LiteSVM, `test_deadman.rs`) passed, 0 failed.
- `cargo clippy --all-targets -- -W clippy::arithmetic_side_effects -W clippy::unwrap_used -W clippy::expect_used -W clippy::panic`: 2 hits in program code (I-9). The remaining 290 hits are `unwrap` calls in tests.
- CU (`compute_unit_profile`):

  | Instruction               | CU     |
  | ------------------------- | ------ |
  | `create_vault` (8 rules)  | 16,782 |
  | `pulse`                   | 13,354 |
  | `update_policy` (8 rules) | 16,406 |
  | `lockdown`                | 12,817 |
  | `execute_sol_rule`        | 21,381 |

  All are far below the limits. Loops are bounded by `MAX_RULES = 8`.

- PoCs for L-1: 2 tests in a scratch copy of the workspace (outside the repo), both pass.
- solana-dev `program_autofixer` on `subscription.rs` and `recover_legacy_vault`: no issues.
- Devnet `getProgramAccounts` was used to size the legacy-layout exposure (L-2, I-1).
- Not run:
  - `cargo audit` and `cargo geiger` (not installed);
  - Trident fuzzing (not set up);
  - `anchor build --verifiable` (needs Docker).

## Verdict

The program is ready for an external audit. There are no Critical, High or Medium findings.

Before mainnet:

- fix L-1 (remap or clear `stipend_paid` in `apply_policy`);
- restrict or remove `recover_legacy_vault` (L-2);
- decide on pro-rata vesting releases (L-3) and on rejecting permanent-delegate mints (L-4);
- move the admin and upgrade authority to a multisig with a timelock (I-4).

An external audit is recommended before mainnet, because the program holds user funds.

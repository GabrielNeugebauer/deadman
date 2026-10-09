//! Stateful fuzz test for the Deadman program.
//!
//! Each iteration builds one world (config, an SPL mint that is the SKR
//! mint in half the worlds, an owner with up to three plans, four
//! beneficiaries) and then runs random
//! flows against it. Every program call goes through `exec`, which snapshots
//! the tracked accounts before and after and, when the transaction succeeds,
//! checks the invariants in `check`:
//!
//! - INV-CONSERVE: lamports and tokens across vaults, beneficiaries,
//!   treasury, owner and the rest of the tracked set are conserved (tokens
//!   up to the burned share of SKR fees, which leaves the mint supply).
//! - INV-DEADLINE: an inheritance tier pays (or is skipped) only after its
//!   deadline, in per-asset order.
//! - INV-ONCE: a rule never pays twice; paid history survives `update_plan`.
//! - INV-VEST: vesting never releases more than the installments elapsed.
//! - INV-FEE: fee <= gross * configured bps (the SKR rate for SKR payouts),
//!   and exactly `skr_burn_bps` of an SKR fee is burned.
//! - INV-RESERVE: withdrawals never dip into skipped-tier reserves, and a
//!   plan with a pending reserve does not close.
//! - INV-FINAL: a fully released plan's rules, label and policy never change.
//! - INV-RENT: closing returns exactly `rent_paid` to `rent_payer`.
//! - INV-STIPEND: the gas stipend is paid at most once per rule and never
//!   out of SOL owed to vesting beneficiaries or skipped tiers.
//! - INV-LOCK: no withdrawal, policy change, revocation or close while locked.
//!
//! Set `FUZZ_STIPEND_LIVENESS=1` to also require that an eligible rule gets
//! its stipend (ON-L1, fixed).

use fuzz_accounts::*;
use trident_fuzz::fuzzing::*;
mod fuzz_accounts;
mod types;
use borsh::BorshSerialize;
use solana_sdk::rent::Rent;
use types::deadman::*;
use types::*;

/// Like `assert!`, but also prints to stderr: Trident only reports panic
/// messages through its progress bar, which drops them off a terminal.
macro_rules! inv {
    ($c:expr, $($a:tt)+) => {
        if !$c {
            let m = format!($($a)+);
            eprintln!("INVARIANT FAILED: {m}");
            panic!("{m}");
        }
    };
}

macro_rules! inv_eq {
    ($l:expr, $r:expr, $($a:tt)+) => {{
        let (l, r) = (&$l, &$r);
        if l != r {
            let m = format!("{} (left {:?}, right {:?})", format!($($a)+), l, r);
            eprintln!("INVARIANT FAILED: {m}");
            panic!("{m}");
        }
    }};
}

const T0: i64 = 1_800_000_000;
const DAY: i64 = 86_400;
const SOL: u64 = LAMPORTS_PER_SOL;
const BPS: u128 = 10_000;
const CLOAK_STIPEND: u64 = 12_000_000;
const ZCASH_STIPEND: u64 = 3_000_000;
const PLANS: usize = 3;
const BENS: usize = 4;
const TOKEN_PROGRAM: Pubkey = pubkey!("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
const ADMIN: Pubkey = Pubkey::new_from_array([7u8; 32]);

#[derive(Clone, Copy, Debug)]
enum Op {
    Other,
    CreatePlan(usize),
    UpdatePlan(usize),
    Pay {
        plan: usize,
        index: usize,
        token: bool,
        vesting: bool,
    },
    Skip(usize, usize),
    Withdraw(usize),
    Revoke(usize),
    Close(usize),
}

#[derive(Clone)]
struct VaultSnap {
    v: Vault,
    lamports: u64,
    len: usize,
}

struct Snap {
    now: i64,
    lamports: Vec<u64>,
    tokens: Vec<u64>,
    vaults: Vec<Option<VaultSnap>>,
    config: Option<Config>,
    supply: u64,
}

#[derive(Default, Clone)]
struct World {
    treasury: Pubkey,
    owner: Pubkey,
    sponsor: Pubkey,
    guard: Pubkey,
    guardian: Pubkey,
    keeper: Pubkey,
    bens: Vec<Pubkey>,
    mint: Pubkey,
    mint_auth: Pubkey,
    owner_ata: Pubkey,
    treasury_ata: Pubkey,
    /// The world's mint is the configured SKR mint.
    skr: bool,
    ben_atas: Vec<Pubkey>,
    vaults: Vec<Pubkey>,
    vault_atas: Vec<Pubkey>,
    /// Ghost: stipends received per rule, aligned with each vault's rules.
    stipends: Vec<Vec<u8>>,
    lamport_keys: Vec<Pubkey>,
    token_keys: Vec<Pubkey>,
}

#[derive(FuzzTestMethods)]
struct FuzzTest {
    trident: Trident,
    fuzz_accounts: AccountAddresses,
    w: World,
}

fn bytes<T: BorshSerialize>(t: &T) -> Vec<u8> {
    let mut v = Vec::new();
    t.serialize(&mut v).unwrap();
    v
}

fn is_private(r: &Rail) -> bool {
    !matches!(r, Rail::Solana)
}

fn stipend_of(r: &Rail) -> u64 {
    match r {
        Rail::Solana => 0,
        Rail::Cloak => CLOAK_STIPEND,
        Rail::Zcash => ZCASH_STIPEND,
    }
}

fn is_vesting(v: &Vault) -> bool {
    matches!(v.kind, PlanKind::Vesting)
}

fn completed(v: &Vault) -> bool {
    v.rules.iter().all(|r| r.executed_at != 0)
}

/// Independent model of what schedule `i` may have released by `now`.
fn model_vested(v: &Vault, i: usize, now: i64) -> u64 {
    let r = &v.rules[i];
    let end = if v.revoked_at != 0 {
        now.min(v.revoked_at)
    } else {
        now
    };
    let elapsed = end as i128 - v.start_at as i128;
    if elapsed < r.after_secs as i128 {
        return 0;
    }
    if elapsed >= r.duration_secs as i128 {
        return r.amount;
    }
    let p = v.vest_period_secs as i128;
    let unlocked = if p > 0 { (elapsed / p) * p } else { elapsed };
    let unlocked = unlocked.max(0) as u128;
    (r.amount as u128 * unlocked / r.duration_secs as u128) as u64
}

fn model_cap(v: &Vault, i: usize) -> u64 {
    if v.revoked_at != 0 {
        model_vested(v, i, v.revoked_at)
    } else {
        v.rules[i].amount
    }
}

fn model_committed_sol(v: &Vault) -> u64 {
    if !is_vesting(v) {
        return 0;
    }
    (0..v.rules.len())
        .filter(|&i| v.rules[i].mint.is_none())
        .map(|i| model_cap(v, i).saturating_sub(v.rules[i].released))
        .sum()
}

fn model_reserved_sol(v: &Vault) -> u64 {
    v.rules
        .iter()
        .filter(|r| r.mint.is_none() && r.executed_at == 0 && r.skipped_at != 0)
        .map(|r| r.reserved)
        .sum()
}

#[flow_executor]
impl FuzzTest {
    fn new() -> Self {
        Self {
            trident: Trident::default(),
            fuzz_accounts: AccountAddresses::default(),
            w: World::default(),
        }
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    fn key(&mut self) -> Pubkey {
        self.trident.random_pubkey()
    }

    fn rent_min(&self, len: usize) -> u64 {
        self.trident.get_sysvar::<Rent>().minimum_balance(len)
    }

    fn lamports(&mut self, k: &Pubkey) -> u64 {
        self.trident.get_account(k).lamports()
    }

    fn token_amount(&mut self, k: &Pubkey) -> u64 {
        let acc = self.trident.get_account(k);
        let d = acc.data();
        if d.len() >= 72 {
            u64::from_le_bytes(d[64..72].try_into().unwrap())
        } else {
            0
        }
    }

    fn vault_snap(&mut self, plan: usize) -> Option<VaultSnap> {
        let addr = self.w.vaults[plan];
        let acc = self.trident.get_account(&addr);
        if acc.owner() != &program_id() || acc.data().len() < 8 {
            return None;
        }
        let v = self.trident.get_account_with_type::<Vault>(&addr, 8)?;
        Some(VaultSnap {
            v,
            lamports: acc.lamports(),
            len: acc.data().len(),
        })
    }

    fn snapshot(&mut self) -> Snap {
        let lk = self.w.lamport_keys.clone();
        let tk = self.w.token_keys.clone();
        let lamports = lk.iter().map(|k| self.lamports(k)).collect();
        let tokens = tk.iter().map(|k| self.token_amount(k)).collect();
        let vaults = (0..PLANS).map(|p| self.vault_snap(p)).collect();
        let config = self
            .trident
            .get_account_with_type::<Config>(&self.config_pda(), 8);
        let mint = self.w.mint;
        let supply = {
            let acc = self.trident.get_account(&mint);
            let d = acc.data();
            if d.len() >= 44 {
                u64::from_le_bytes(d[36..44].try_into().unwrap())
            } else {
                0
            }
        };
        Snap {
            now: self.trident.get_current_timestamp(),
            lamports,
            tokens,
            vaults,
            config,
            supply,
        }
    }

    fn config_pda(&self) -> Pubkey {
        self.trident
            .find_program_address(&[b"config"], &program_id())
            .0
    }

    /// Plan creation and edits take the token mint in the remaining accounts.
    fn mint_meta(&self) -> Vec<AccountMeta> {
        vec![AccountMeta::new_readonly(self.w.mint, false)]
    }

    fn lamp_idx(&self, k: &Pubkey) -> usize {
        self.w.lamport_keys.iter().position(|x| x == k).unwrap()
    }

    fn tok_idx(&self, k: &Pubkey) -> usize {
        self.w.token_keys.iter().position(|x| x == k).unwrap()
    }

    fn ldelta(&self, b: &Snap, a: &Snap, k: &Pubkey) -> i128 {
        let i = self.lamp_idx(k);
        a.lamports[i] as i128 - b.lamports[i] as i128
    }

    fn tdelta(&self, b: &Snap, a: &Snap, k: &Pubkey) -> i128 {
        let i = self.tok_idx(k);
        a.tokens[i] as i128 - b.tokens[i] as i128
    }

    fn pick_plan(&mut self) -> usize {
        self.trident.random_from_range(0..PLANS)
    }

    fn pick_ben(&mut self) -> Pubkey {
        let i = self.trident.random_from_range(0..BENS);
        self.w.bens[i]
    }

    fn pick_rail(&mut self) -> Rail {
        match self.trident.random_from_range(0..4u8) {
            0 | 1 => Rail::Solana,
            2 => Rail::Cloak,
            _ => Rail::Zcash,
        }
    }

    fn pick_mint(&mut self) -> Option<Pubkey> {
        if self.trident.random_bool() {
            None
        } else {
            Some(self.w.mint)
        }
    }

    fn pick_delay(&mut self) -> i64 {
        match self.trident.random_from_range(0..5u8) {
            0 => 60,
            1 => self.trident.random_from_range(60..3_600i64),
            2 => DAY,
            3 => self.trident.random_from_range(DAY..30 * DAY),
            _ => 10 * DAY,
        }
    }

    fn random_rules(&mut self) -> Vec<RuleInput> {
        let n = self.trident.random_from_range(1..=4usize);
        let mut delays: Vec<i64> = (0..n).map(|_| self.pick_delay()).collect();
        delays.sort();
        delays
            .into_iter()
            .map(|after| {
                let percent = self.trident.random_bool();
                let amount = if percent {
                    self.trident.random_from_range(1..=10_000u64)
                } else {
                    match self.trident.random_from_range(0..3u8) {
                        0 => self.trident.random_from_range(1..1_000_000u64),
                        1 => self.trident.random_from_range(1..5 * SOL),
                        _ => u64::MAX,
                    }
                };
                RuleInput {
                    beneficiary: self.pick_ben(),
                    rail: self.pick_rail(),
                    after_secs: after,
                    mint: self.pick_mint(),
                    mode: if percent {
                        AmountMode::Percent
                    } else {
                        AmountMode::Fixed
                    },
                    amount,
                }
            })
            .collect()
    }

    /// Runs `ixs` as one transaction and checks every invariant on success.
    fn exec(&mut self, ixs: &[Instruction], label: &str, op: Op) -> bool {
        let before = self.snapshot();
        let res = self.trident.process_transaction(ixs, Some(label));
        if !res.is_success() {
            return false;
        }
        let after = self.snapshot();
        self.check(label, op, &before, &after);
        true
    }

    // ------------------------------------------------------------------
    // invariants
    // ------------------------------------------------------------------

    fn check(&mut self, label: &str, op: Op, b: &Snap, a: &Snap) {
        let now = a.now;

        // INV-CONSERVE (lamports): no program instruction creates or
        // destroys lamports inside the tracked set.
        let lb: u128 = b.lamports.iter().map(|&x| x as u128).sum();
        let la: u128 = a.lamports.iter().map(|&x| x as u128).sum();
        inv_eq!(
            lb,
            la,
            "INV-CONSERVE lamports changed in {label}: {lb} -> {la}"
        );
        // INV-CONSERVE (tokens): only an SKR fee's burned share leaves.
        let tb: u128 = b.tokens.iter().map(|&x| x as u128).sum();
        let ta: u128 = a.tokens.iter().map(|&x| x as u128).sum();
        inv!(a.supply <= b.supply, "INV-CONSERVE supply grew in {label}");
        let burned = (b.supply - a.supply) as u128;
        inv_eq!(
            tb,
            ta + burned,
            "INV-CONSERVE tokens changed in {label}: {tb} -> {ta} (+{burned} burned)"
        );
        if burned > 0 {
            inv!(
                self.w.skr && matches!(op, Op::Pay { token: true, .. }),
                "INV-FEE {label} burned tokens outside an SKR payout"
            );
        }

        for p in 0..PLANS {
            let (vb, va) = (&b.vaults[p], &a.vaults[p]);
            if let Some(va) = va {
                // INV-RENT: a live vault always keeps the rent it was paid.
                inv!(
                    va.lamports >= va.v.rent_paid,
                    "INV-RENT vault {p} below rent_paid after {label}"
                );
            }
            let (Some(vb), Some(va)) = (vb, va) else {
                continue;
            };
            // INV-ONCE: paid or skipped history is never lost or rewritten,
            // except the target tier of a payout (a skipped tier being claimed).
            let target = match op {
                Op::Pay { plan, index, .. } if plan == p => Some(index),
                _ => None,
            };
            if !matches!(op, Op::UpdatePlan(q) if q == p) {
                for (i, rb) in vb.v.rules.iter().enumerate() {
                    if (rb.executed_at != 0 || rb.skipped_at != 0) && Some(i) != target {
                        inv!(
                            i < va.v.rules.len() && bytes(rb) == bytes(&va.v.rules[i]),
                            "INV-ONCE history rule {i} of plan {p} changed by {label}"
                        );
                    }
                }
            }
            for (i, rb) in vb.v.rules.iter().enumerate() {
                if rb.executed_at != 0 {
                    let kept =
                        va.v.rules
                            .iter()
                            .filter(|ra| bytes(*ra) == bytes(rb))
                            .count();
                    inv!(
                        kept >= 1,
                        "INV-ONCE executed rule {i} of plan {p} vanished after {label}"
                    );
                }
            }
            let executed_b = vb.v.rules.iter().filter(|r| r.executed_at != 0).count();
            let executed_a = va.v.rules.iter().filter(|r| r.executed_at != 0).count();
            inv!(
                executed_a >= executed_b,
                "INV-ONCE executed count dropped in plan {p} by {label}"
            );
            // INV-FINAL: a fully released plan never changes policy.
            if !vb.v.rules.is_empty() && completed(&vb.v) {
                inv!(
                    bytes(&vb.v.rules) == bytes(&va.v.rules)
                        && vb.v.label == va.v.label
                        && vb.v.lock_secs == va.v.lock_secs
                        && vb.v.skip_grace_secs == va.v.skip_grace_secs
                        && bytes(&vb.v.guardian) == bytes(&va.v.guardian)
                        && vb.v.revoked_at == va.v.revoked_at
                        && vb.v.last_pulse <= va.v.last_pulse,
                    "INV-FINAL completed plan {p} changed by {label}"
                );
                inv!(
                    !matches!(op, Op::UpdatePlan(q) | Op::Revoke(q) if q == p),
                    "INV-FINAL {label} succeeded on completed plan {p}"
                );
            }
        }

        match op {
            Op::Other | Op::CreatePlan(_) => {}
            Op::UpdatePlan(p) => {
                let vb = b.vaults[p].as_ref().unwrap();
                inv!(now >= vb.v.locked_until, "INV-LOCK update while locked");
                let va = a.vaults[p].as_ref().unwrap();
                // Remap the stipend ghost exactly as apply_policy keeps history.
                let mut ghost: Vec<u8> =
                    vb.v.rules
                        .iter()
                        .enumerate()
                        .filter(|(_, r)| r.executed_at != 0 || r.skipped_at != 0)
                        .map(|(i, _)| self.w.stipends[p].get(i).copied().unwrap_or(0))
                        .collect();
                ghost.resize(va.v.rules.len(), 0);
                self.w.stipends[p] = ghost;
            }
            Op::Withdraw(p) => {
                let vb = b.vaults[p].as_ref().unwrap();
                inv!(now >= vb.v.locked_until, "INV-LOCK withdraw while locked");
                let va = a.vaults[p].as_ref().unwrap();
                let reserve = self.rent_min(va.len).max(va.v.rent_paid);
                let free = va.lamports.saturating_sub(reserve);
                let committed = model_committed_sol(&va.v) + model_reserved_sol(&va.v);
                let committed_b = model_committed_sol(&vb.v) + model_reserved_sol(&vb.v);
                let free_b = vb.lamports.saturating_sub(reserve);
                if free_b >= committed_b {
                    inv!(
                        free >= committed,
                        "INV-RESERVE withdraw_sol dipped into owed SOL: free {free} < {committed}"
                    );
                }
                let vt = self.w.vault_atas[p];
                let tok_after = a.tokens[self.tok_idx(&vt)];
                let tok_before = b.tokens[self.tok_idx(&vt)];
                let owed_tok = |v: &Vault| -> u64 {
                    let vest: u64 = if is_vesting(v) {
                        (0..v.rules.len())
                            .filter(|&i| v.rules[i].mint.is_some())
                            .map(|i| model_cap(v, i).saturating_sub(v.rules[i].released))
                            .sum()
                    } else {
                        0
                    };
                    let reserved: u64 = v
                        .rules
                        .iter()
                        .filter(|r| r.mint.is_some() && r.executed_at == 0 && r.skipped_at != 0)
                        .map(|r| r.reserved)
                        .sum();
                    vest + reserved
                };
                if tok_after != tok_before && tok_before >= owed_tok(&vb.v) {
                    inv!(
                        tok_after >= owed_tok(&va.v),
                        "INV-RESERVE withdraw_token dipped into owed tokens"
                    );
                }
            }
            Op::Revoke(p) => {
                let vb = b.vaults[p].as_ref().unwrap();
                inv!(now >= vb.v.locked_until, "INV-LOCK revoke while locked");
            }
            Op::Close(p) => {
                let vb = b.vaults[p].as_ref().unwrap();
                inv!(now >= vb.v.locked_until, "INV-LOCK close while locked");
                inv!(a.vaults[p].is_none(), "close left the vault open");
                let vault_key = self.w.vaults[p];
                inv_eq!(
                    a.lamports[self.lamp_idx(&vault_key)],
                    0,
                    "INV-RENT closed vault kept lamports"
                );
                let owner = self.w.owner;
                let rp = vb.v.rent_payer;
                inv!(
                    !vb.v
                        .rules
                        .iter()
                        .any(|r| r.executed_at == 0 && r.skipped_at != 0 && r.reserved > 0),
                    "INV-RESERVE plan {p} closed with a pending skipped reserve"
                );
                if is_vesting(&vb.v) {
                    for i in 0..vb.v.rules.len() {
                        inv!(
                            vb.v.rules[i].released >= model_cap(&vb.v, i),
                            "INV-VEST closed vesting plan {p} still owing rule {i}"
                        );
                    }
                }
                if rp != owner {
                    inv_eq!(
                        self.ldelta(b, a, &rp),
                        vb.v.rent_paid as i128,
                        "INV-RENT rent_payer did not get exactly rent_paid back"
                    );
                    inv_eq!(
                        self.ldelta(b, a, &owner),
                        vb.lamports as i128 - vb.v.rent_paid as i128,
                        "INV-RENT owner did not get the excess"
                    );
                } else {
                    inv_eq!(
                        self.ldelta(b, a, &owner),
                        vb.lamports as i128,
                        "INV-RENT owner-paid close did not return everything"
                    );
                }
            }
            Op::Skip(p, i) => {
                let vb = b.vaults[p].as_ref().unwrap();
                let rb = &vb.v.rules[i];
                inv!(!is_vesting(&vb.v), "skip succeeded on a vesting plan");
                let due = vb.v.last_pulse as i128 + rb.after_secs as i128;
                // TridentSVM's clock follows wall time, so the program's
                // `now` is the recorded skipped_at, within [b.now, a.now].
                let t = a.vaults[p].as_ref().unwrap().v.rules[i].skipped_at;
                inv!(
                    t >= b.now && t <= now,
                    "skipped_at {t} outside [{}, {now}]",
                    b.now
                );
                inv!(
                    (t as i128) > due + vb.v.skip_grace_secs as i128,
                    "INV-DEADLINE rule {i} skipped at {t} before due+grace"
                );
                inv!(
                    rb.executed_at == 0 && rb.skipped_at == 0,
                    "INV-ONCE skipped a settled rule"
                );
                for r in &vb.v.rules[..i] {
                    inv!(
                        bytes(&r.mint) != bytes(&rb.mint)
                            || r.executed_at != 0
                            || r.skipped_at != 0,
                        "INV-DEADLINE skip out of per-asset order"
                    );
                }
            }
            Op::Pay {
                plan: p,
                index: i,
                token,
                vesting,
            } => self.check_pay(label, p, i, token, vesting, b, a),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn check_pay(
        &mut self,
        label: &str,
        p: usize,
        i: usize,
        token: bool,
        vesting: bool,
        b: &Snap,
        a: &Snap,
    ) {
        let now = a.now;
        let vb = b.vaults[p].as_ref().expect("paid from a missing vault");
        let va = a.vaults[p].as_ref().expect("vault vanished on payout");
        let rb = vb.v.rules[i].clone();
        let ra = va.v.rules[i].clone();
        inv_eq!(
            is_vesting(&vb.v),
            vesting,
            "{label} ran on the wrong plan kind"
        );
        // INV-ONCE
        inv_eq!(rb.executed_at, 0, "INV-ONCE {label} paid rule {i} twice");
        let ben = rb.beneficiary;
        let vault_key = self.w.vaults[p];
        let treasury = self.w.treasury;

        // gross / net / fee in the paid asset
        let burned = (b.supply - a.supply) as i128;
        let (gross, net, fee) = if token {
            let vt = self.w.vault_atas[p];
            let bi = self.w.bens.iter().position(|x| *x == ben).unwrap();
            let bt = self.w.ben_atas[bi];
            let tt = self.w.treasury_ata;
            (
                -self.tdelta(b, a, &vt),
                self.tdelta(b, a, &bt),
                self.tdelta(b, a, &tt) + burned,
            )
        } else {
            (
                -self.ldelta(b, a, &vault_key),
                self.ldelta(b, a, &ben),
                self.ldelta(b, a, &treasury),
            )
        };
        inv!(gross > 0, "{label} succeeded with nothing paid");
        inv!(
            net >= 0 && fee >= 0,
            "{label} negative leg net={net} fee={fee}"
        );
        inv_eq!(net + fee, gross, "INV-CONSERVE {label}: net+fee != gross");

        // INV-FEE
        let cfg = b.config.as_ref().unwrap();
        let skr = token && self.w.skr && cfg.skr_mint == self.w.mint;
        let bps = if skr {
            cfg.fee_bps_skr
        } else {
            match rb.rail {
                Rail::Solana => cfg.fee_bps_public,
                _ => cfg.fee_bps_private,
            }
        } as u128;
        inv!(bps <= 500, "INV-FEE configured bps above the 5% cap");
        let max_fee = (gross as u128) * bps / BPS;
        inv!(
            (fee as u128) <= max_fee,
            "INV-FEE {label}: fee {fee} > {max_fee} (gross {gross}, bps {bps})"
        );
        if token {
            inv_eq!(
                fee as u128,
                max_fee,
                "INV-FEE {label}: token fee is not the configured rate"
            );
        }
        let want_burn = if skr {
            (fee as u128) * cfg.skr_burn_bps as u128 / BPS
        } else {
            0
        };
        inv_eq!(
            burned as u128,
            want_burn,
            "INV-FEE {label}: burned share differs from skr_burn_bps"
        );

        if vesting {
            // INV-VEST
            let vested = model_vested(&vb.v, i, now);
            inv!(
                ra.released <= vested,
                "INV-VEST rule {i}: released {} > vested {vested} at {now}",
                ra.released
            );
            inv!(ra.released <= rb.amount, "INV-VEST released above total");
            inv_eq!(
                (ra.released - rb.released) as i128,
                gross,
                "INV-VEST released delta != gross"
            );
            if ra.executed_at != 0 {
                inv!(
                    ra.released >= model_cap(&va.v, i),
                    "INV-VEST rule {i} marked done before its cap"
                );
            }
        } else {
            // INV-DEADLINE
            let t = ra.executed_at;
            inv!(
                t >= b.now && t <= now,
                "{label}: executed_at {t} outside [{}, {now}]",
                b.now
            );
            if rb.skipped_at == 0 {
                let due = vb.v.last_pulse as i128 + rb.after_secs as i128;
                inv!(
                    t as i128 > due,
                    "INV-DEADLINE rule {i} paid at {t}, due after {due}"
                );
                for r in &vb.v.rules[..i] {
                    inv!(
                        bytes(&r.mint) != bytes(&rb.mint)
                            || r.executed_at != 0
                            || r.skipped_at != 0,
                        "INV-DEADLINE rule {i} paid out of per-asset order"
                    );
                }
                if matches!(rb.mode, AmountMode::Fixed) {
                    inv!(gross as u128 <= rb.amount as u128, "fixed tier overpaid");
                }
            } else if rb.reserved > 0 {
                inv!(
                    gross as u128 <= rb.reserved as u128,
                    "skipped tier paid above its reserve"
                );
            }
        }

        // INV-STIPEND
        if token {
            let stip = -self.ldelta(b, a, &vault_key);
            let ben_gain = self.ldelta(b, a, &ben);
            inv_eq!(stip, ben_gain, "stipend leg not conserved");
            let expected = stipend_of(&rb.rail) as i128;
            inv!(
                stip == 0 || stip == expected,
                "INV-STIPEND unexpected lamports {stip} on {label}"
            );
            if stip > 0 {
                let g = &mut self.w.stipends[p];
                if g.len() <= i {
                    g.resize(i + 1, 0);
                }
                g[i] += 1;
                inv!(
                    g[i] <= 1,
                    "INV-STIPEND rule {i} of plan {p} got two stipends"
                );
                let reserve = self.rent_min(va.len).max(va.v.rent_paid);
                let free_b = vb.lamports.saturating_sub(reserve);
                let owed = model_committed_sol(&vb.v) + model_reserved_sol(&vb.v);
                inv!(
                    free_b >= owed + stip as u64,
                    "INV-STIPEND paid out of owed SOL: free {free_b}, owed {owed}"
                );
            } else if std::env::var("FUZZ_STIPEND_LIVENESS").is_ok()
                && is_private(&rb.rail)
                && self.w.stipends[p].get(i).copied().unwrap_or(0) == 0
            {
                let ben_before = b.lamports[self.lamp_idx(&ben)];
                let reserve = self.rent_min(vb.len).max(vb.v.rent_paid);
                let free_b = vb.lamports.saturating_sub(reserve);
                let owed = model_committed_sol(&vb.v) + model_reserved_sol(&vb.v);
                inv!(
                    ben_before >= stipend_of(&rb.rail)
                        || free_b.saturating_sub(owed) < stipend_of(&rb.rail),
                    "INV-STIPEND rule {i} of plan {p} eligible but denied its stipend"
                );
            }
        }
    }

    // ------------------------------------------------------------------
    // setup
    // ------------------------------------------------------------------

    #[init]
    fn start(&mut self) {
        self.trident.warp_to_timestamp(T0);
        let mut w = World {
            treasury: self.key(),
            owner: self.key(),
            sponsor: self.key(),
            guard: self.key(),
            guardian: self.key(),
            keeper: self.key(),
            mint: self.key(),
            mint_auth: self.key(),
            ..World::default()
        };
        w.bens = (0..BENS).map(|_| self.trident.random_pubkey()).collect();
        for k in [w.owner, w.sponsor, w.guard, w.guardian, w.keeper, ADMIN] {
            self.trident.airdrop(&k, 1_000 * SOL);
        }
        if self.trident.random_bool() {
            self.trident.airdrop(&w.treasury, SOL);
        }
        for i in 0..BENS {
            // Mix funded, dust and empty beneficiaries.
            let amt = match self.trident.random_from_range(0..3u8) {
                0 => 0,
                1 => 1_000_000,
                _ => SOL,
            };
            if amt > 0 {
                let b = w.bens[i];
                self.trident.airdrop(&b, amt);
            }
        }
        w.vaults = (0..PLANS as u16)
            .map(|id| {
                self.trident
                    .find_program_address(
                        &[b"vault", w.owner.as_ref(), &id.to_le_bytes()],
                        &program_id(),
                    )
                    .0
            })
            .collect();
        w.stipends = vec![Vec::new(); PLANS];

        // Mint and token accounts, all funded by the Trident payer.
        let payer = self.trident.payer().pubkey();
        let ixs = self
            .trident
            .initialize_mint(&payer, &w.mint, 6, &w.mint_auth, None);
        inv!(
            self.trident.process_transaction(&ixs, None).is_success(),
            "setup failed"
        );
        let mut holders = vec![w.owner, w.treasury];
        holders.extend(w.bens.iter().copied());
        holders.extend(w.vaults.iter().copied());
        for h in &holders {
            let ix = self
                .trident
                .initialize_associated_token_account(&payer, &w.mint, h);
            inv!(
                self.trident.process_transaction(&[ix], None).is_success(),
                "setup failed"
            );
        }
        let mint = w.mint;
        let ata =
            |t: &Trident, h: &Pubkey| t.get_associated_token_address(&mint, h, &TOKEN_PROGRAM);
        w.owner_ata = ata(&self.trident, &w.owner);
        w.treasury_ata = ata(&self.trident, &w.treasury);
        w.ben_atas = w.bens.iter().map(|b| ata(&self.trident, b)).collect();
        w.vault_atas = w.vaults.iter().map(|v| ata(&self.trident, v)).collect();
        let ix = self
            .trident
            .mint_to(&w.owner_ata, &w.mint, &w.mint_auth, 1_000_000_000_000);
        inv!(
            self.trident.process_transaction(&[ix], None).is_success(),
            "setup failed"
        );

        let mut lk = vec![
            w.owner, w.sponsor, w.guard, w.guardian, w.keeper, w.treasury, ADMIN,
        ];
        lk.extend(w.bens.iter().copied());
        lk.extend(w.vaults.iter().copied());
        let mut tk = vec![w.owner_ata, w.treasury_ata];
        tk.extend(w.ben_atas.iter().copied());
        tk.extend(w.vault_atas.iter().copied());
        w.lamport_keys = lk;
        w.token_keys = tk;
        self.w = w;
        let extra = self.config_pda();
        self.w.lamport_keys.push(extra);

        // Default config, then random fees; half the worlds pay in SKR.
        self.w.skr = self.trident.random_bool();
        let skr_mint = if self.w.skr {
            self.w.mint
        } else {
            Pubkey::default()
        };
        let pd = self.trident.get_program_data_address_v3(&program_id());
        let ix = InitConfigInstruction::data(InitConfigInstructionData::new(skr_mint))
            .accounts(InitConfigInstructionAccounts::new(
                ADMIN,
                self.config_pda(),
                self.w.treasury,
                pd,
            ))
            .instruction();
        inv!(
            self.exec(&[ix], "init_config", Op::Other),
            "init_config failed"
        );
        if self.trident.random_bool() {
            self.set_config();
        }
    }

    // ------------------------------------------------------------------
    // flows
    // ------------------------------------------------------------------

    #[flow(weight = 8)]
    fn create_plan(&mut self) {
        let p = self.pick_plan();
        let rules = self.random_rules();
        let payer = if self.trident.random_bool() {
            self.w.owner
        } else {
            self.w.sponsor
        };
        let lock = self.trident.random_from_range(60..=30 * DAY);
        let grace = self.trident.random_from_range(60..=30 * DAY);
        let ix = CreatePlanInstruction::data(CreatePlanInstructionData::new(
            p as u16,
            "fuzz".to_string(),
            self.w.guard,
            lock,
            grace,
            rules,
        ))
        .accounts(CreatePlanInstructionAccounts::new(
            self.w.owner,
            payer,
            self.w.vaults[p],
        ))
        .remaining_accounts(self.mint_meta())
        .instruction();
        if self.exec(&[ix], "create_plan", Op::CreatePlan(p)) {
            let n = self.vault_snap(p).unwrap().v.rules.len();
            self.w.stipends[p] = vec![0; n];
            self.fund(p);
        }
    }

    #[flow(weight = 6)]
    fn create_vesting(&mut self) {
        let p = self.pick_plan();
        let now = self.trident.get_current_timestamp();
        let n = self.trident.random_from_range(1..=3usize);
        let mut schedules = Vec::new();
        let mut min_dur = i64::MAX;
        for _ in 0..n {
            let duration = match self.trident.random_from_range(0..3u8) {
                0 => self.trident.random_from_range(60..3_600i64),
                1 => self.trident.random_from_range(DAY..100 * DAY),
                _ => self.trident.random_from_range(1..=20 * 366 * DAY),
            };
            let cliff = if self.trident.random_bool() {
                0
            } else {
                self.trident.random_from_range(0..=duration)
            };
            min_dur = min_dur.min(duration);
            let total = match self.trident.random_from_range(0..3u8) {
                0 => self.trident.random_from_range(1..1_000u64),
                1 => self.trident.random_from_range(1..10 * SOL),
                _ => self.trident.random_from_range(1..1_000_000_000u64),
            };
            schedules.push(VestingInput {
                beneficiary: self.pick_ben(),
                rail: self.pick_rail(),
                mint: self.pick_mint(),
                total,
                cliff_secs: cliff,
                duration_secs: duration,
            });
        }
        let period = match self.trident.random_from_range(0..3u8) {
            0 => 0,
            _ if min_dur < 60 => 0,
            _ => self.trident.random_from_range(60..=min_dur),
        };
        let start = now + self.trident.random_from_range(-30 * DAY..=30 * DAY);
        let payer = if self.trident.random_bool() {
            self.w.owner
        } else {
            self.w.sponsor
        };
        let revocable = self.trident.random_bool();
        let lock = self.trident.random_from_range(60..=30 * DAY);
        let ix = CreateVestingInstruction::data(CreateVestingInstructionData::new(
            p as u16,
            "vest".to_string(),
            self.w.guard,
            lock,
            start,
            revocable,
            schedules,
            period,
        ))
        .accounts(CreateVestingInstructionAccounts::new(
            self.w.owner,
            payer,
            self.w.vaults[p],
        ))
        .remaining_accounts(self.mint_meta())
        .instruction();
        if self.exec(&[ix], "create_vesting", Op::CreatePlan(p)) {
            let n = self.vault_snap(p).unwrap().v.rules.len();
            self.w.stipends[p] = vec![0; n];
            self.fund(p);
        }
    }

    /// External deposits (not program calls, so not invariant-checked).
    fn fund(&mut self, p: usize) {
        let sol = match self.trident.random_from_range(0..4u8) {
            0 => 0,
            1 => self.trident.random_from_range(1..20_000_000u64),
            _ => self.trident.random_from_range(1..20 * SOL),
        };
        let v = self.w.vaults[p];
        self.trident.airdrop(&v, sol);
        let tok = self.trident.random_from_range(0..2_000_000_000u64);
        let (vt, mint, auth) = (self.w.vault_atas[p], self.w.mint, self.w.mint_auth);
        let ix = self.trident.mint_to(&vt, &mint, &auth, tok);
        self.trident.process_transaction(&[ix], None);
    }

    #[flow(weight = 4)]
    fn deposit(&mut self) {
        let p = self.pick_plan();
        self.fund(p);
    }

    #[flow(weight = 18)]
    fn warp(&mut self) {
        let secs = match self.trident.random_from_range(0..5u8) {
            0 => self.trident.random_from_range(1..120i64),
            1 => self.trident.random_from_range(60..3_600i64),
            2 => self.trident.random_from_range(DAY / 2..2 * DAY),
            3 => self.trident.random_from_range(5 * DAY..15 * DAY),
            _ => self.trident.random_from_range(20 * DAY..60 * DAY),
        };
        self.trident.forward_in_time(secs);
    }

    #[flow(weight = 6)]
    fn pulse(&mut self) {
        let p = self.pick_plan();
        let signer = if self.trident.random_bool() {
            self.w.owner
        } else {
            self.w.guard
        };
        let ix = PulseInstruction::data(PulseInstructionData::new())
            .accounts(PulseInstructionAccounts::new(signer, self.w.vaults[p]))
            .instruction();
        self.exec(&[ix], "pulse", Op::Other);
    }

    #[flow(weight = 10)]
    fn execute_sol_rule(&mut self) {
        let p = self.pick_plan();
        let Some(vs) = self.vault_snap(p) else { return };
        let i = self.trident.random_from_range(0..vs.v.rules.len() + 1);
        let ben =
            vs.v.rules
                .get(i)
                .map(|r| r.beneficiary)
                .unwrap_or(self.w.bens[0]);
        let vesting = is_vesting(&vs.v);
        let accs = (
            self.w.keeper,
            self.w.vaults[p],
            self.config_pda(),
            ben,
            self.w.treasury,
        );
        let ix = if vesting {
            ReleaseVestedSolInstruction::data(ReleaseVestedSolInstructionData::new(i as u8))
                .accounts(ReleaseVestedSolInstructionAccounts::new(
                    accs.0, accs.1, accs.2, accs.3, accs.4,
                ))
                .instruction()
        } else {
            ExecuteSolRuleInstruction::data(ExecuteSolRuleInstructionData::new(i as u8))
                .accounts(ExecuteSolRuleInstructionAccounts::new(
                    accs.0, accs.1, accs.2, accs.3, accs.4,
                ))
                .instruction()
        };
        let label = if vesting {
            "release_vested_sol"
        } else {
            "execute_sol_rule"
        };
        self.exec(
            &[ix],
            label,
            Op::Pay {
                plan: p,
                index: i,
                token: false,
                vesting,
            },
        );
    }

    #[flow(weight = 10)]
    fn execute_token_rule(&mut self) {
        let p = self.pick_plan();
        let Some(vs) = self.vault_snap(p) else { return };
        let i = self.trident.random_from_range(0..vs.v.rules.len() + 1);
        let ben =
            vs.v.rules
                .get(i)
                .map(|r| r.beneficiary)
                .unwrap_or(self.w.bens[0]);
        let bi = self.w.bens.iter().position(|x| *x == ben).unwrap();
        let vesting = is_vesting(&vs.v);
        // The treasury ATA is optional (program id = none); without it only
        // a payout that leaves nothing for the treasury may succeed.
        let with_treasury = self.trident.random_from_range(0..4u8) != 0;
        let treasury_token = if with_treasury {
            self.w.treasury_ata
        } else {
            program_id()
        };
        let a = (
            self.w.keeper,
            self.w.vaults[p],
            self.config_pda(),
            self.w.mint,
            self.w.vault_atas[p],
            ben,
            self.w.ben_atas[bi],
            treasury_token,
        );
        let ix = if vesting {
            ReleaseVestedTokenInstruction::data(ReleaseVestedTokenInstructionData::new(i as u8))
                .accounts(ReleaseVestedTokenInstructionAccounts::new(
                    a.0, a.1, a.2, a.3, a.4, a.5, a.6, a.7,
                ))
                .instruction()
        } else {
            ExecuteTokenRuleInstruction::data(ExecuteTokenRuleInstructionData::new(i as u8))
                .accounts(ExecuteTokenRuleInstructionAccounts::new(
                    a.0, a.1, a.2, a.3, a.4, a.5, a.6, a.7,
                ))
                .instruction()
        };
        let tt = self.w.treasury_ata;
        let t_before = self.token_amount(&tt);
        let label = if vesting {
            "release_vested_token"
        } else {
            "execute_token_rule"
        };
        let ok = self.exec(
            &[ix],
            label,
            Op::Pay {
                plan: p,
                index: i,
                token: true,
                vesting,
            },
        );
        if ok && !with_treasury {
            inv_eq!(
                self.token_amount(&tt),
                t_before,
                "INV-FEE {label} paid the treasury without its account"
            );
        }
    }

    #[flow(weight = 6)]
    fn skip_rule(&mut self) {
        let p = self.pick_plan();
        let Some(vs) = self.vault_snap(p) else { return };
        let i = self.trident.random_from_range(0..vs.v.rules.len() + 1);
        let token = vs.v.rules.get(i).is_some_and(|r| r.mint.is_some());
        let vt = if token {
            self.w.vault_atas[p]
        } else {
            program_id()
        };
        let ix = SkipRuleInstruction::data(SkipRuleInstructionData::new(i as u8))
            .accounts(SkipRuleInstructionAccounts::new(
                self.w.keeper,
                self.w.vaults[p],
                vt,
            ))
            .instruction();
        self.exec(&[ix], "skip_rule", Op::Skip(p, i));
    }

    #[flow(weight = 6)]
    fn withdraw(&mut self) {
        let p = self.pick_plan();
        let amount = match self.trident.random_from_range(0..3u8) {
            0 => self.trident.random_from_range(1..1_000_000u64),
            1 => self.trident.random_from_range(1..10 * SOL),
            _ => self.trident.random_from_range(1..2_000_000_000u64),
        };
        let ix = if self.trident.random_bool() {
            WithdrawSolInstruction::data(WithdrawSolInstructionData::new(amount))
                .accounts(WithdrawSolInstructionAccounts::new(
                    self.w.owner,
                    self.w.vaults[p],
                ))
                .instruction()
        } else {
            WithdrawTokenInstruction::data(WithdrawTokenInstructionData::new(amount))
                .accounts(WithdrawTokenInstructionAccounts::new(
                    self.w.owner,
                    self.w.vaults[p],
                    self.w.mint,
                    self.w.vault_atas[p],
                    self.w.owner_ata,
                    TOKEN_PROGRAM,
                ))
                .instruction()
        };
        self.exec(&[ix], "withdraw", Op::Withdraw(p));
    }

    #[flow(weight = 6)]
    fn update_plan(&mut self) {
        let p = self.pick_plan();
        let rules = self.random_rules();
        let lock = self.trident.random_from_range(60..=30 * DAY);
        let grace = self.trident.random_from_range(60..=30 * DAY);
        let guardian = if self.trident.random_bool() {
            Some(self.w.guardian)
        } else {
            None
        };
        let ix = UpdatePlanInstruction::data(UpdatePlanInstructionData::new(
            "upd".to_string(),
            lock,
            grace,
            rules,
            guardian,
        ))
        .accounts(UpdatePlanInstructionAccounts::new(
            self.w.owner,
            self.w.vaults[p],
        ))
        .remaining_accounts(self.mint_meta())
        .instruction();
        self.exec(&[ix], "update_plan", Op::UpdatePlan(p));
    }

    #[flow(weight = 4)]
    fn lockdown_or_unlock(&mut self) {
        let p = self.pick_plan();
        let ix = match self.trident.random_from_range(0..4u8) {
            0 => UnlockInstruction::data(UnlockInstructionData::new())
                .accounts(UnlockInstructionAccounts::new(
                    self.w.owner,
                    self.w.guardian,
                    self.w.vaults[p],
                ))
                .instruction(),
            k => {
                let s = [self.w.owner, self.w.guard, self.w.guardian][k as usize - 1];
                LockdownInstruction::data(LockdownInstructionData::new())
                    .accounts(LockdownInstructionAccounts::new(s, self.w.vaults[p]))
                    .instruction()
            }
        };
        self.exec(&[ix], "lockdown_or_unlock", Op::Other);
    }

    #[flow(weight = 4)]
    fn revoke(&mut self) {
        let p = self.pick_plan();
        let ix = RevokeVestingInstruction::data(RevokeVestingInstructionData::new())
            .accounts(RevokeVestingInstructionAccounts::new(
                self.w.owner,
                self.w.vaults[p],
            ))
            .instruction();
        self.exec(&[ix], "revoke_vesting", Op::Revoke(p));
    }

    #[flow(weight = 4)]
    fn close(&mut self) {
        let p = self.pick_plan();
        let Some(vs) = self.vault_snap(p) else { return };
        let ix = CloseVaultInstruction::data(CloseVaultInstructionData::new())
            .accounts(CloseVaultInstructionAccounts::new(
                self.w.owner,
                self.w.vaults[p],
                vs.v.rent_payer,
            ))
            .instruction();
        if self.exec(&[ix], "close_vault", Op::Close(p)) {
            self.w.stipends[p].clear();
        }
    }

    #[flow(weight = 3)]
    fn set_config(&mut self) {
        let fp = self.trident.random_from_range(0..=600u16);
        let fv = self.trident.random_from_range(0..=600u16);
        let fs = self.trident.random_from_range(0..=600u16);
        let burn = self.trident.random_from_range(0..=11_000u16);
        let skr_mint = if self.w.skr {
            self.w.mint
        } else {
            Pubkey::default()
        };
        // Sometimes an unusable treasury (a sysvar or a program account).
        let treasury = match self.trident.random_from_range(0..8u8) {
            0 => pubkey!("SysvarC1ock11111111111111111111111111111111"),
            1 => self.config_pda(),
            _ => self.w.treasury,
        };
        let ix =
            SetConfigInstruction::data(SetConfigInstructionData::new(fp, fv, skr_mint, fs, burn))
                .accounts(SetConfigInstructionAccounts::new(
                    ADMIN,
                    self.config_pda(),
                    treasury,
                ))
                .instruction();
        if self.exec(&[ix], "set_config", Op::Other) {
            inv!(
                fp <= 500 && fv <= 500 && fs <= 500 && burn <= 10_000,
                "INV-FEE set_config accepted bps above cap"
            );
            inv_eq!(
                treasury,
                self.w.treasury,
                "set_config accepted an unusable treasury"
            );
        }
    }

    /// Two-step admin rotation: only the proposed key can accept. The
    /// fuzz admin re-proposes itself, so later admin flows keep working.
    #[flow(weight = 3)]
    fn rotate_admin(&mut self) {
        let config = self.config_pda();
        let ix = ProposeAdminInstruction::data(ProposeAdminInstructionData::new(ADMIN))
            .accounts(ProposeAdminInstructionAccounts::new(ADMIN, config))
            .instruction();
        inv!(
            self.exec(&[ix], "propose_admin", Op::Other),
            "propose_admin by the admin failed"
        );
        let intruder = self.w.keeper;
        let ix = AcceptAdminInstruction::data(AcceptAdminInstructionData::new())
            .accounts(AcceptAdminInstructionAccounts::new(intruder, config))
            .instruction();
        inv!(
            !self.exec(&[ix], "accept_admin", Op::Other),
            "accept_admin succeeded for a key nobody proposed"
        );
        if self.trident.random_bool() {
            let ix = AcceptAdminInstruction::data(AcceptAdminInstructionData::new())
                .accounts(AcceptAdminInstructionAccounts::new(ADMIN, config))
                .instruction();
            inv!(
                self.exec(&[ix], "accept_admin", Op::Other),
                "accept_admin by the proposed key failed"
            );
        }
        let c = self
            .trident
            .get_account_with_type::<Config>(&config, 8)
            .unwrap();
        inv_eq!(c.admin, ADMIN, "admin changed without its own acceptance");
    }

    #[flow(weight = 2)]
    fn set_guard(&mut self) {
        let p = self.pick_plan();
        let g = if self.trident.random_bool() {
            self.w.guard
        } else {
            self.w.keeper
        };
        let ix = SetGuardInstruction::data(SetGuardInstructionData::new(g))
            .accounts(SetGuardInstructionAccounts::new(
                self.w.owner,
                self.w.vaults[p],
            ))
            .instruction();
        self.exec(&[ix], "set_guard", Op::Other);
    }

    #[end]
    fn end(&mut self) {}
}

fn main() {
    let iters = std::env::var("FUZZ_ITERS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(2_000);
    let flows = std::env::var("FUZZ_FLOWS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(120);
    FuzzTest::fuzz(iters, flows);
}

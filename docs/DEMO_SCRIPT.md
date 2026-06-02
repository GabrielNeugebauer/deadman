# Deadman Demo Script (90 seconds)

This video is for Solana Mobile CLOCK IN (due 2026-10-08) and is reused for the Colosseum World's Fair submission. Everything is shot on devnet with real transactions.

## Setup (off camera)

- **Phone A (owner):** a Seeker with the Deadman APK and Seed Vault Wallet on devnet. Create a vault with these settings:
  - **Interval 120 s, grace 60 s.** The program minimum for grace is 60 s, so the switch can be fired 3 minutes after the last pulse.
  - **Lock 300 s** (the app's Demo cadence), so the lockdown clearly outlasts the duress beat.
  - **1 heir at 10 000 bps:** phone B's wallet.
  - **Deposit:** 1 devnet SOL.
  - **App PIN and a different duress PIN.**
- **Phone B (heir):** a second Android device or an emulator running the same app, connected to the heir wallet and funded with about 0.05 devnet SOL for fees.
- A laptop with the vault address open in Solana Explorer (devnet) for cut-ins.
- **Shoot it as one continuous take** of about 4 to 5 minutes, then edit it down to 90 s with jump cuts. Keep the in-app countdown or a wall clock in frame across every cut, so viewers can see the wait was real.
- Do not tap Pulse or perform any owner action after beat 3. Any of them resets the switch.
- The owner's failed withdrawal in beat 4 does not count as a pulse, because the transaction reverts.

## Beats

| Time      | Picture                                                                                                                                                                                                                                                            | Voice-over / on-screen text                                                                                                                                                 |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0:00–0:07 | Close-up of the Seeker in a hand. Title card: "Deadman: the self-custody safety net for Seeker."                                                                                                                                                                   | "Your Seed Vault protects your keys from malware. It does not protect them from silence, coercion or loss."                                                                 |
| 0:07–0:15 | Phone A home screen. Vault balance 1 SOL, heir listed, countdown visible. Caption: "Demo interval: 2 min (normally 7 to 90 days)."                                                                                                                                 | "One vault on-chain. If I stop checking in, my heir can claim."                                                                                                             |
| 0:15–0:27 | **Pulse.** Thumb on the sensor, a check-in animation, the streak counter, and the countdown resetting. No wallet screen appears. Quick cut-in of the explorer `pulse` tx, signed by the guard key.                                                                 | "This is the daily Pulse: three seconds, one fingerprint, no wallet prompt. A device guard key signs it, and that key can only check in or lock, never withdraw."           |
| 0:27–0:37 | **Duress.** The screen locks. A second person's hand reaches in: "Open it." The owner types the duress PIN. The app opens to a normal-looking home screen.                                                                                                         | "Now someone is forcing me to open it. I enter my duress PIN instead."                                                                                                      |
| 0:37–0:52 | The attacker taps Withdraw. The app spins, then shows "Seed Vault timed out. Try again later." Under the duress PIN no wallet prompt or on-chain error ever reveals the lock. Cut-in: explorer showing the `lockdown` tx signed by the guard key a few seconds earlier. | "That PIN already locked the vault on-chain, with no prompt for the attacker to notice. The withdrawal fails, the heirs can't be changed, and I can't lift the lock alone." |
| 0:52–1:05 | **Phone B, Family Circle.** "Owner: last check-in 2m ago." The countdown runs out (jump cut, clock in frame). A Trigger button appears.                                                                                                                            | "My heir sees my liveness every day. If I go silent, the switch opens. Here it's two minutes plus grace."                                                                   |
| 1:05–1:20 | Phone B taps Trigger, then Claim, and approves both in its wallet. The balance rises by about 0.99 SOL. Cut-in: explorer `claim_sol` showing the heir payout and the success fee to the treasury.                                                                  | "Anyone can fire an expired switch. The heir claims their share, and Deadman takes at most a 1% success fee. Notice that the lockdown didn't block inheritance."            |
| 1:20–1:30 | End card: "One vault. Three threats. Silence, coercion, loss." Program ID `ACHVLMoL...HofL` (devnet), GitHub URL. "Unaudited hackathon build."                                                                                                                     | "Deadman. Built for Seeker. Open source, live on devnet."                                                                                                                   |

## Checks before recording

- The `Config` PDA exists on devnet with a nonzero `fee_bps`, so the fee line shows up in the claim. The program caps it at 100 bps.
- The duress PIN path really signs `lockdown` with the guard key. Confirm in the explorer that the `LockedDown` event's `by` field is the guard key.
- Pick the actual fee before filming and make the payout figure match it. At `fee_bps = 100`, the heir receives 0.99 of the vault's withdrawable SOL.
- Only claim on camera what the build does on camera. If a screen is not finished, cut that line rather than describe it.
- Before saying "open source," make sure the GitHub repository is public.

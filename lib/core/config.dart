/// Network and program constants. Override at build time, e.g.
/// `--dart-define=CLUSTER=mainnet-beta --dart-define=RPC_URL=https://...`.
class AppConfig {
  static const cluster = String.fromEnvironment(
    'CLUSTER',
    defaultValue: 'devnet',
  );
  static const isMainnet = cluster == 'mainnet-beta';

  static const rpcUrl = String.fromEnvironment(
    'RPC_URL',
    defaultValue: isMainnet
        ? 'https://api.mainnet-beta.solana.com'
        : 'https://api.devnet.solana.com',
  );
  static const wsUrl = String.fromEnvironment(
    'WS_URL',
    defaultValue: isMainnet
        ? 'wss://api.mainnet-beta.solana.com'
        : 'wss://api.devnet.solana.com',
  );

  static const programId = 'ACHVLMoLDM3YPpGbNST4cZW4Tf2jx6nzJGuusyLJHofL';

  static const appIdentityName = 'Deadman';
  static const appIdentityUri = 'https://deadman.app';
  static const appIconPath = 'favicon.ico';

  /// Kora node that sponsors guard-key transactions (pulse, lockdown) for
  /// free, so the guard key never needs SOL. Empty = guard pays its own fee.
  static const koraSponsorUrl = String.fromEnvironment('KORA_SPONSOR_URL');

  static const koraApiKey = String.fromEnvironment('KORA_API_KEY');

  /// Kora node that pays network fees and rent for wallet-signed owner
  /// transactions and charges the owner in USDC instead (opt-in in the
  /// Security tab). Empty = owners always pay in SOL.
  static const koraPaymasterUrl = String.fromEnvironment('KORA_PAYMASTER_URL');

  /// USDC mint: Circle's devnet USDC by default on devnet. Override with
  /// `--dart-define=USDC_MINT=...` (e.g. a test mint).
  static const usdcMint = String.fromEnvironment(
    'USDC_MINT',
    defaultValue: isMainnet
        ? 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v'
        : '4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU',
  );
  static const usdcDecimals = 6;

  /// SOL sent to the device guard key at setup to pay pulse fees.
  static const guardFundingLamports = 10000000;

  /// Program bounds for the owner-chosen skip grace period.
  static const minSkipGraceSecs = 60;
  static const maxSkipGraceSecs = 366 * 86400;
  static const defaultSkipGraceSecs = 30 * 86400;

  /// Warn this long before guard-key check-ins stop being accepted.
  static const guardWindowWarnSecs = 30 * 86400;
}

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

  /// SOL sent to the device guard key at setup to pay pulse fees.
  static const guardFundingLamports = 10000000;
}

/// Network and program constants. Devnet until mainnet launch.
class AppConfig {
  static const cluster = 'devnet';
  static const rpcUrl = 'https://api.devnet.solana.com';
  static const wsUrl = 'wss://api.devnet.solana.com';

  static const programId = 'ACHVLMoLDM3YPpGbNST4cZW4Tf2jx6nzJGuusyLJHofL';

  /// Devnet stand-in for SKR (set after `scripts/devnet-setup`).
  static const skrMint = String.fromEnvironment('SKR_MINT');
  static const skrDecimals = 6;

  static const appIdentityName = 'Deadman';
  static const appIdentityUri = 'https://deadman.app';
  static const appIconPath = 'favicon.ico';

  /// SOL sent to the device guard key at setup to pay pulse fees.
  static const guardFundingLamports = 10000000;
}

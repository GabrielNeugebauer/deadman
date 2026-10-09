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

  /// Where the web app sends people for the Android app.
  static const androidAppUrl = String.fromEnvironment(
    'ANDROID_APP_URL',
    defaultValue:
        'https://github.com/GabrielNeugebauer/deadman/releases/latest',
  );

  /// Kora node that sponsors guard-key transactions (pulse, lockdown) for
  /// free, so the guard key never needs SOL. Empty = guard pays its own fee.
  static const koraSponsorUrl = String.fromEnvironment('KORA_SPONSOR_URL');

  static const koraApiKey = String.fromEnvironment('KORA_API_KEY');

  /// Kora node that pays network fees and rent for wallet-signed owner
  /// transactions and charges the owner in USDC instead (opt-in in the
  /// Security tab). Empty = owners always pay in SOL.
  static const koraPaymasterUrl = String.fromEnvironment('KORA_PAYMASTER_URL');

  /// The paymaster's fee payer, which must also be its payment address
  /// (audit M-3): the app refuses a paymaster that answers with another
  /// key, so a tampered response cannot redirect the fee. Defaults to the
  /// Deadman devnet signer; a mainnet build must set KORA_PAYMASTER_SIGNER,
  /// or paying fees in USDC is refused.
  static const koraPaymasterSigner = String.fromEnvironment(
    'KORA_PAYMASTER_SIGNER',
    defaultValue: isMainnet
        ? ''
        : 'HCAeeSv4vBHGqWLEV7AdWK19xFYuosN76jwUGuoCs3pL',
  );

  /// The most the app pays the paymaster for one transaction, in base units
  /// of the fee token (3 USDC); a higher quote is refused.
  static const koraMaxFee = int.fromEnvironment(
    'KORA_MAX_FEE',
    defaultValue: 3000000,
  );

  /// USDC mint. On devnet: our devnet test USDC, accepted by the devnet
  /// paymaster. Circle devnet USDC via
  /// `--dart-define=USDC_MINT=4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU`.
  static const usdcMint = String.fromEnvironment(
    'USDC_MINT',
    defaultValue: isMainnet
        ? 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v'
        : 'Ew8Z6hhRp7MFK8KJAxRqaBQvBEjtRj4Y4K4YhWsPMFGk',
  );
  static const usdcDecimals = 6;

  /// Solana Mobile's Seeker token (classic SPL Token, 6 decimals). Payouts
  /// in it pay the lower SKR release fee (`Config.fee_bps_skr`), part of
  /// which is burned; the program reads the mint from `Config.skr_mint`. On
  /// devnet: our test mint.
  static const skrMint = String.fromEnvironment(
    'SKR_MINT',
    defaultValue: isMainnet
        ? 'SKRbvo6Gf7GondiT3BbTfuRDPqLWei4j2Qy2NPGZhW3'
        : '4JX81qZWhPPT38Tn4ZswaS2DyH3PffdrFqbYgsoZCuHc',
  );
  static const skrDecimals = 6;

  /// ORE (classic SPL Token, 11 decimals): a plan asset like any token. On
  /// devnet: our test mint.
  static const oreMint = String.fromEnvironment(
    'ORE_MINT',
    defaultValue: isMainnet
        ? 'oreoU2P8bN6jkk3jbaiVxYnG1dCXcYxwhwyK9jSybcp'
        : '6KdRjrWYouFLmEcNeDpJkc9AUgzvmE7cn3DbAx2KfSyt',
  );
  static const oreDecimals = 11;

  /// SOL sent to the device guard key at setup to pay pulse fees.
  static const guardFundingLamports = 10000000;

  /// Program bounds for the owner-chosen skip grace period.
  static const minSkipGraceSecs = 60;
  static const maxSkipGraceSecs = 366 * 86400;
  static const defaultSkipGraceSecs = 30 * 86400;

  /// Warn this long before guard-key check-ins stop being accepted.
  static const guardWindowWarnSecs = 30 * 86400;
}

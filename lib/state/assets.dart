import '../core/config.dart';

const jitoSolMint = 'J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn';

/// A token the app knows how to name and format. [mint] null = SOL.
class AssetInfo {
  const AssetInfo(this.mint, this.symbol, this.decimals, this.displayDigits);

  final String? mint;
  final String symbol;
  final int decimals;

  /// Fraction digits shown in balances and labels.
  final int displayDigits;
}

const solAsset = AssetInfo(null, 'SOL', 9, 3);
const usdcAsset = AssetInfo(
  AppConfig.usdcMint,
  'USDC',
  AppConfig.usdcDecimals,
  2,
);
const jitoSolAsset = AssetInfo(jitoSolMint, 'JitoSOL', 9, 4);

/// Assets offered as one-tap choices; any other mint is "Other token".
const presetAssets = [
  solAsset,
  usdcAsset,
  if (AppConfig.isMainnet) jitoSolAsset,
];

AssetInfo? knownAsset(String? mint) {
  if (mint == null) return solAsset;
  if (mint == AppConfig.usdcMint) return usdcAsset;
  if (mint == jitoSolMint) return jitoSolAsset;
  return null;
}

String _short(String a) =>
    a.length <= 10 ? a : '${a.substring(0, 4)}…${a.substring(a.length - 4)}';

/// "SOL", "USDC", or a shortened mint for unknown tokens.
String assetSymbol(String? mint) => knownAsset(mint)?.symbol ?? _short(mint!);

/// Input suffix for an amount of [mint]: its symbol, or "units" (base
/// units) for an unknown token.
String unitLabel(String? mint) => knownAsset(mint)?.symbol ?? 'units';

BigInt _pow10(int n) => BigInt.from(10).pow(n);

/// [base] units as a decimal with at most [digits] fraction digits (rounded
/// half up), trailing zeros trimmed: 1500000 @6 -> "1.5".
String formatUnits(int base, int decimals, {int? digits}) {
  final neg = base < 0;
  final scale = _pow10(decimals);
  final v = BigInt.from(base).abs();
  var whole = v ~/ scale;
  var frac = v % scale;
  var width = decimals;
  if (digits != null && digits < decimals) {
    final drop = _pow10(decimals - digits);
    frac = (frac + drop ~/ BigInt.two) ~/ drop;
    if (frac >= _pow10(digits)) {
      whole += BigInt.one;
      frac = BigInt.zero;
    }
    width = digits;
  }
  final f = width == 0
      ? ''
      : frac.toString().padLeft(width, '0').replaceFirst(RegExp(r'0+$'), '');
  return '${neg ? '-' : ''}$whole${f.isEmpty ? '' : '.$f'}';
}

/// Exact decimal parse into base units; null when not a non-negative number
/// or it has more fraction digits than [decimals]. Accepts "," as the
/// decimal separator.
int? parseUnits(String input, int decimals) {
  final m = RegExp(r'^(\d*)(?:\.(\d*))?$')
      .firstMatch(input.trim().replaceAll(',', '.'));
  if (m == null) return null;
  final whole = m[1]!;
  final frac = m[2] ?? '';
  if (whole.isEmpty && frac.isEmpty) return null;
  if (frac.length > decimals) return null;
  final v =
      BigInt.parse(whole.isEmpty ? '0' : whole) * _pow10(decimals) +
      (frac.isEmpty ? BigInt.zero : BigInt.parse(frac.padRight(decimals, '0')));
  if (v.bitLength > 63) return null;
  return v.toInt();
}

/// What the user types for an amount of [mint]: decimal for known assets,
/// base units for an unknown token.
int? parseAmount(String input, String? mint) {
  final info = knownAsset(mint);
  if (info != null) return parseUnits(input, info.decimals);
  final v = int.tryParse(input.trim());
  return v == null || v < 0 ? null : v;
}

/// [base] units of [mint] as the editor shows them (full precision).
String amountInput(int base, String? mint) {
  final info = knownAsset(mint);
  return info == null ? '$base' : formatUnits(base, info.decimals);
}

/// Number part of [amountText].
String amountNumber(int base, String? mint) {
  final info = knownAsset(mint);
  if (info == null) return '$base';
  if (mint == null) {
    return (base / 1000000000).toStringAsFixed(info.displayDigits);
  }
  final s = formatUnits(base, info.decimals, digits: info.displayDigits);
  // Tiny amounts would round to 0: show them exactly.
  return s == '0' && base != 0 ? formatUnits(base, info.decimals) : s;
}

/// "0.100 SOL", "12.5 USDC", "42 units ABCD…WXYZ".
String amountText(int base, String? mint) => knownAsset(mint) == null
    ? '$base units ${_short(mint!)}'
    : '${amountNumber(base, mint)} ${assetSymbol(mint)}';

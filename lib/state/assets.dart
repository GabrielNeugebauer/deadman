import '../core/config.dart';

const jitoSolMint = 'J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn';

/// A token the app knows how to name and format. [mint] null = SOL.
class AssetInfo {
  const AssetInfo(
    this.mint,
    this.symbol,
    this.decimals,
    this.displayDigits, {
    this.nft = false,
    this.imageUrl,
  });

  final String? mint;

  /// Ticker, or an NFT's name.
  final String symbol;
  final int decimals;

  /// Fraction digits shown in balances and labels.
  final int displayDigits;

  /// A classic (non-programmable) NFT: one of a kind, sent whole.
  final bool nft;

  /// NFT image (off-chain metadata); null when unknown.
  final String? imageUrl;
}

const solAsset = AssetInfo(null, 'SOL', 9, 3);
const usdcAsset = AssetInfo(
  AppConfig.usdcMint,
  'USDC',
  AppConfig.usdcDecimals,
  2,
);
const jitoSolAsset = AssetInfo(jitoSolMint, 'JitoSOL', 9, 4);
const skrAsset = AssetInfo(AppConfig.skrMint, 'SKR', AppConfig.skrDecimals, 2);
const oreAsset = AssetInfo(AppConfig.oreMint, 'ORE', AppConfig.oreDecimals, 4);

const circleDevnetUsdcMint = '4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU';

/// Mints named for display only (not offered as presets), so plans made
/// with another USDC build still read clearly. [AppConfig.usdcMint] wins.
const _knownMints = <String, AssetInfo>{
  if (!AppConfig.isMainnet)
    circleDevnetUsdcMint: AssetInfo(
      circleDevnetUsdcMint,
      'USDC (Circle)',
      AppConfig.usdcDecimals,
      2,
    ),
};

/// Assets offered as one-tap choices; any other mint is "Other token".
const presetAssets = [
  solAsset,
  usdcAsset,
  skrAsset,
  oreAsset,
  if (AppConfig.isMainnet) jitoSolAsset,
];

/// NFTs named so far (from the wallet or a plan's mints): mint -> info.
final _nfts = <String, AssetInfo>{};

/// Names [mint] as an NFT from now on; returns its info. A name that reads
/// as a preset token's symbol keeps a piece of its mint, as in
/// [rememberToken].
AssetInfo rememberNft(String mint, String name, {String? imageUrl}) {
  final clean = displaySymbol(name);
  return _nfts[mint] = AssetInfo(
    mint,
    clean.isEmpty
        ? 'NFT ${_short(mint)}'
        : isLookalike(mint, clean)
        ? '$clean·${mint.substring(0, 4)}'
        : clean,
    0,
    0,
    nft: true,
    imageUrl: imageUrl,
  );
}

/// Forgets every remembered NFT (tests).
void forgetNfts() => _nfts.clear();

/// Tokens named from the Jupiter token list: mint -> info.
final _tokens = <String, AssetInfo>{};

/// The preset token whose symbol [symbol] reads as, when that token is not
/// [mint]: "USDC", "usdc", "USDС" (Cyrillic Es), "ＵＳＤＣ" or "USDC" plus a
/// zero-width space all name [usdcAsset] for any other mint.
AssetInfo? lookalikeOf(String mint, String symbol) {
  final s = symbolSkeleton(symbol);
  if (s.isEmpty) return null;
  for (final a in [...presetAssets, jitoSolAsset]) {
    if (a.mint != mint && symbolSkeleton(a.symbol) == s) return a;
  }
  return null;
}

/// A token symbol the app already uses for another mint ("USDC" on a token
/// that is not [AppConfig.usdcMint]), compared by [symbolSkeleton].
bool isLookalike(String mint, String symbol) =>
    lookalikeOf(mint, symbol) != null;

/// Names [mint] as a listed token from now on, so its amounts read in whole
/// units. A lookalike symbol keeps a piece of its mint ("USDC·Ab12"), so it
/// can never read as the real one; so does any symbol when [tagged] (an
/// unverified or flagged token).
AssetInfo rememberToken(
  String mint,
  String symbol,
  int decimals, {
  String? imageUrl,
  bool tagged = false,
}) {
  final shown = displaySymbol(symbol);
  final clean = shown.isEmpty ? _short(mint) : shown;
  return _tokens[mint] = AssetInfo(
    mint,
    shown.isNotEmpty && (tagged || isLookalike(mint, clean))
        ? '$clean·${mint.substring(0, 4)}'
        : clean,
    decimals,
    decimals < 4 ? decimals : 4,
    imageUrl: imageUrl,
  );
}

/// [symbol] trimmed, without control, format (zero-width, bidi override)
/// or variation-selector characters, which could hide or reorder text.
String displaySymbol(String symbol) =>
    String.fromCharCodes(symbol.runes.where((r) => !_invisible(r))).trim();

/// What [symbol] looks like, as upper-case ASCII where it can be: a
/// compatibility fold close to NFKC (full-width, mathematical, circled,
/// letter-like and accented forms), invisible characters and whitespace
/// dropped, and common confusables (Cyrillic, Greek, Cherokee, Lisu, small
/// capitals) mapped to the Latin letter they imitate.
String symbolSkeleton(String symbol) {
  final out = StringBuffer();
  for (final r in symbol.runes) {
    if (_invisible(r) || _space(r)) continue;
    final folded = _fold(r);
    if (folded != null) {
      out.write(folded);
    } else {
      out.writeCharCode(r);
    }
  }
  final upper = out.toString().toUpperCase();
  // toUpperCase can turn an unmapped lower-case confusable into a mapped
  // upper-case one (Cyrillic "ѕ" -> "Ѕ"); fold again.
  final again = StringBuffer();
  for (final r in upper.runes) {
    again.write(_fold(r) ?? String.fromCharCode(r));
  }
  return again.toString().toUpperCase();
}

bool _invisible(int r) =>
    r < 0x20 ||
    (r >= 0x7F && r <= 0x9F) ||
    r == 0xAD ||
    r == 0x34F ||
    r == 0x61C ||
    r == 0x115F ||
    r == 0x1160 ||
    r == 0x17B4 ||
    r == 0x17B5 ||
    (r >= 0x180B && r <= 0x180F) ||
    (r >= 0x200B && r <= 0x200F) ||
    (r >= 0x202A && r <= 0x202E) ||
    (r >= 0x2060 && r <= 0x206F) ||
    r == 0x3164 ||
    (r >= 0xFE00 && r <= 0xFE0F) ||
    r == 0xFEFF ||
    r == 0xFFA0 ||
    (r >= 0xFFF0 && r <= 0xFFFB) ||
    (r >= 0x1D173 && r <= 0x1D17A) ||
    (r >= 0xE0000 && r <= 0xE0FFF) ||
    // Combining marks: "C" + U+0301 reads as a C.
    (r >= 0x300 && r <= 0x36F) ||
    (r >= 0x1AB0 && r <= 0x1AFF) ||
    (r >= 0x1DC0 && r <= 0x1DFF) ||
    (r >= 0x20D0 && r <= 0x20FF) ||
    (r >= 0xFE20 && r <= 0xFE2F);

bool _space(int r) =>
    r == 0x20 ||
    r == 0xA0 ||
    r == 0x1680 ||
    (r >= 0x2000 && r <= 0x200A) ||
    r == 0x2028 ||
    r == 0x2029 ||
    r == 0x202F ||
    r == 0x205F ||
    r == 0x3000;

/// The ASCII [r] stands for, or null when it is ASCII or unknown.
String? _fold(int r) {
  if (r < 0x80) return null;
  String chr(int base, int i) => String.fromCharCode(base + i);
  // Full-width ASCII.
  if (r >= 0xFF01 && r <= 0xFF5E) return String.fromCharCode(r - 0xFEE0);
  // Mathematical alphanumerics: 13 styles of A-Z a-z, then 5 of 0-9.
  if (r >= 0x1D400 && r <= 0x1D6A3) {
    final i = (r - 0x1D400) % 52;
    return i < 26 ? chr(0x41, i) : chr(0x61, i - 26);
  }
  if (r >= 0x1D7CE && r <= 0x1D7FF) return chr(0x30, (r - 0x1D7CE) % 10);
  // Circled, parenthesized, squared and regional-indicator letters.
  if (r >= 0x24B6 && r <= 0x24CF) return chr(0x41, r - 0x24B6);
  if (r >= 0x24D0 && r <= 0x24E9) return chr(0x61, r - 0x24D0);
  if (r >= 0x249C && r <= 0x24B5) return chr(0x61, r - 0x249C);
  if (r >= 0x2460 && r <= 0x2468) return chr(0x31, r - 0x2460);
  if (r >= 0x1F110 && r <= 0x1F129) return chr(0x41, r - 0x1F110);
  if (r >= 0x1F130 && r <= 0x1F149) return chr(0x41, r - 0x1F130);
  if (r >= 0x1F150 && r <= 0x1F169) return chr(0x41, r - 0x1F150);
  if (r >= 0x1F170 && r <= 0x1F189) return chr(0x41, r - 0x1F170);
  if (r >= 0x1F1E6 && r <= 0x1F1FF) return chr(0x41, r - 0x1F1E6);
  if (r >= 0x1FBF0 && r <= 0x1FBF9) return chr(0x30, r - 0x1FBF0);
  return _confusables[r];
}

/// Look-alike -> ASCII, built from [_confusableGroups].
final Map<int, String> _confusables = {
  for (final MapEntry(key: ascii, value: forms) in _confusableGroups.entries)
    for (final r in forms.runes) r: ascii,
};

/// ASCII letter or digit -> the characters that render like it. Covers
/// accented Latin (what NFKC leaves composed), letter-like symbols, Roman
/// numerals, small capitals, and Cyrillic, Greek, Armenian, Cherokee and
/// Lisu homoglyphs.
const _confusableGroups = <String, String>{
  'A': 'ÀÁÂÃÄÅĀĂĄǍǞǠǺȀȂȦȺΑАӐӒᎪꓮᴀ',
  'a': 'àáâãäåāăąǎǟǡǻȁȃȧаɑαӑӓ',
  'B': 'ƁɃΒВᏴꓐʙℬ',
  'b': 'ƀƃЬ',
  'C': 'ÇĆĈĊČƇȻϹСᏟꓚᴄℂℭⅭ',
  'c': 'çćĉċčƈȼϲсⅽ',
  'D': 'ĎĐƉƊᎠꓓᴅⅮ',
  'd': 'ďđɗԁⅾ',
  'E': 'ÈÉÊËĒĔĖĘĚȄȆȨɆΕЕЀЁᎬꓰᴇℰ',
  'e': 'èéêëēĕėęěȅȇȩɇеѐёℯ',
  'F': 'ƑϜꓝꜰℱ',
  'G': 'ĜĞĠĢƓǤǦᏀꓖɢ',
  'g': 'ĝğġģǥǧɡ',
  'H': 'ĤĦȞΗНҢҤᎻꓧʜℋℌℍ',
  'h': 'ĥħȟһℎ',
  'I': 'ÌÍÎÏĨĪĬĮİƗǏȈȊΙІЇӀꓲɪℐℑⅠ',
  'i': 'ìíîïĩīĭįıǐȉȋιіїⅰ',
  'J': 'ĴɈЈᎫꓙᴊ',
  'j': 'ĵǰȷɉϳј',
  'K': 'ĶƘǨΚКҚҜᏦꓗᴋK',
  'k': 'ķƙǩκк',
  'L': 'ĹĻĽĿŁȽᏞꓡʟℒⅬ',
  'l': 'ĺļľŀłƚӏℓⅼ',
  'M': 'ΜМᎷꓟᴍℳⅯ',
  'm': 'ⅿ',
  'N': 'ÑŃŅŇƝǸΝꓠɴℕ',
  'n': 'ñńņňǹ',
  'O': 'ÒÓÔÕÖØŌŎŐƟƠǑǪǬǾȌȎȪȬȮȰΟОӦՕꓳᴏ',
  'o': 'òóôõöøōŏőơǒǫǭǿȍȏȫȭȯȱοσоӧօℴ',
  'P': 'ƤΡРᏢꓑᴘℙ',
  'p': 'ƥρр',
  'Q': 'Ԛℚ',
  'q': 'ԛ',
  'R': 'ŔŖŘȐȒɌᏒꓣʀℛℜℝ',
  'r': 'ŕŗřȑȓɍ',
  'S': 'ŚŜŞŠȘЅՏᏚꓢꜱ',
  's': 'śŝşšșѕ',
  'T': 'ŢŤŦƬƮȚΤТᎢꓔᴛ',
  't': 'ţťŧțƫ',
  'U': 'ÙÚÛÜŨŪŬŮŰŲƯǓǕǗǙǛȔȖՍꓴᴜ',
  'u': 'ùúûüũūŭůűųưǔǖǘǚǜȕȗυս',
  'V': 'ƲѴᏙꓦᴠⅤ',
  'v': 'νѵⅴ',
  'W': 'ŴԜᏔꓪᴡ',
  'w': 'ŵԝ',
  'X': 'ΧХꓫⅩ',
  'x': 'χхⅹ',
  'Y': 'ÝŶŸƳȲΥУҮҰꓬʏ',
  'y': 'ýÿŷƴȳуү',
  'Z': 'ŹŻŽƵȤΖᏃꓜᴢℤ',
  'z': 'źżžƶȥ',
  '0': '⁰₀',
  '1': '¹₁',
  '2': '²₂',
  '3': '³₃',
};

/// Forgets every remembered token (tests).
void forgetTokens() => _tokens.clear();

/// [mint] is a remembered NFT.
bool isNft(String? mint) => mint != null && _nfts.containsKey(mint);

AssetInfo? knownAsset(String? mint) {
  if (mint == null) return solAsset;
  if (mint == AppConfig.usdcMint) return usdcAsset;
  if (mint == AppConfig.skrMint) return skrAsset;
  if (mint == AppConfig.oreMint) return oreAsset;
  if (mint == jitoSolMint) return jitoSolAsset;
  return _nfts[mint] ?? _knownMints[mint] ?? _tokens[mint];
}

/// [knownAsset], or an unknown token typed in base units under a
/// shortened mint.
AssetInfo assetInfo(String? mint) =>
    knownAsset(mint) ?? AssetInfo(mint, _short(mint!), 0, 0);

String _short(String a) =>
    a.length <= 10 ? a : '${a.substring(0, 4)}…${a.substring(a.length - 4)}';

/// "SOL", "USDC", or a shortened mint for unknown tokens.
String assetSymbol(String? mint) => knownAsset(mint)?.symbol ?? _short(mint!);

/// Input suffix for an amount of [mint]: its symbol, "NFT", or "units"
/// (base units) for an unknown token.
String unitLabel(String? mint) {
  final info = knownAsset(mint);
  return info == null
      ? 'units'
      : info.nft
      ? 'NFT'
      : info.symbol;
}

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
  if (info == null || info.nft) return '$base';
  if (mint == null) {
    return (base / 1000000000).toStringAsFixed(info.displayDigits);
  }
  final s = formatUnits(base, info.decimals, digits: info.displayDigits);
  // Tiny amounts would round to 0: show them exactly.
  return s == '0' && base != 0 ? formatUnits(base, info.decimals) : s;
}

/// "0.100 SOL", "12.5 USDC", "42 units ABCD…WXYZ"; an NFT by its name
/// ("2 × Name" for an amount other than one).
String amountText(int base, String? mint) {
  final info = knownAsset(mint);
  if (info == null) return '$base units ${_short(mint!)}';
  if (info.nft) return base == 1 ? info.symbol : '$base × ${info.symbol}';
  return '${amountNumber(base, mint)} ${info.symbol}';
}

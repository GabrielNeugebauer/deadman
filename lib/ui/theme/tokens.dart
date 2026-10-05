import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Deadman brand tokens, v2 (docs/brand/v2, "Color and type").
///
/// The seven named colors come from the brand book. The steps between them
/// (pit, raise, line, seam, deep, haze, dust) are read off the app mockups
/// on pages 10-13.
abstract final class DM {
  // Ground and surfaces, darkest to lightest.
  static const void_ = Color(0xFF0A0B0D); // Void: the ground
  static const pit = Color(0xFF131418); // inputs, sunk into a card
  static const grave = Color(0xFF16181C); // Grave: cards
  static const raise = Color(0xFF1F2227); // snackbars, toasts, pressed rows
  static const line = Color(0xFF24272E); // 1px borders, dividers, dim ticks
  static const seam = Color(0xFF2E3138); // input and tag outlines
  static const deep = Color(0xFF0F2A21); // pulse at 13% on void: selected

  // Text, brightest to dimmest.
  static const bone = Color(0xFFF1F0EA); // Bone: primary text
  static const haze = Color(0xFFCED1D7); // ring captions, emphasised prose
  static const dust = Color(0xFFA7ABB3); // data lines, body copy
  static const ash = Color(0xFF8B8F98); // Ash: secondary text, captions

  // The accent and the status hues.
  static const pulse = Color(0xFF3EF5A8); // Pulse: alive, primary actions
  static const missed = Color(0xFFFFB547); // Missed: amber, for warnings
  static const flatline = Color(0xFFFF4D5E); // Flatline: a release is due

  // v1 names, kept so screens compile while they move to the names above.
  static const graphite = grave;
  static const signal = pulse;
  static const tide = pulse;
  static const track = line;
  static const sub = dust;
  static const mist = ash;
  static const onTrack = pulse;
  static const attention = missed;
  static const due = flatline;
  static const locked = bone;
  static const released = ash;
}

/// One skull, four moods (+ the lock). Each value is a state the app
/// already shows, in the brand book's color for it.
enum DMStatus {
  /// The next release tier is counting down from the last check-in.
  alive,

  /// Amber: something needs attention (an interrupted transfer, a
  /// warning). Release countdowns stay [alive].
  missed,

  /// Silent past a release tier: funds go to the beneficiary.
  due,

  /// Every tier has paid out.
  released,

  /// Lockdown active (Panic or the duress PIN). Not in the brand book:
  /// bone on an ash tint, always with the pixel lock.
  locked;

  @Deprecated('Use DMStatus.alive')
  static const onTrack = alive;
  @Deprecated('Use DMStatus.missed')
  static const attention = missed;
}

extension DMStatusX on DMStatus {
  Color get color => switch (this) {
    DMStatus.alive => DM.pulse,
    DMStatus.missed => DM.missed,
    DMStatus.due => DM.flatline,
    DMStatus.released => DM.ash,
    DMStatus.locked => DM.bone,
  };

  /// Sticker word.
  String get label => switch (this) {
    DMStatus.alive => 'ALIVE',
    DMStatus.missed => 'MISSED',
    DMStatus.due => 'TIER DUE',
    DMStatus.released => 'RELEASED',
    DMStatus.locked => 'LOCKED',
  };

  /// Sticker and selected-tile fill: the status color at 13%, which on
  /// void gives the mockups' #0F2A21 / #2A2112 / #2A1417.
  Color get tint => this == DMStatus.locked
      ? DM.ash.withValues(alpha: 0.18)
      : color.withValues(alpha: 0.13);

  /// Unlit ring ticks while this status shows.
  Color get dimTick =>
      this == DMStatus.due ? DM.flatline.withValues(alpha: 0.33) : DM.line;
}

/// Countdown status from the remaining share of the time until the next
/// release (0..1): alive while it counts down, due once it runs out.
DMStatus statusForWindow(
  double remaining, {
  bool releasing = false,
  bool locked = false,
}) {
  if (locked) return DMStatus.locked;
  if (releasing || remaining <= 0) return DMStatus.due;
  return DMStatus.alive;
}

/// 4pt spacing scale. [gutter] is the screen's horizontal padding.
abstract final class DMSpace {
  static const xxs = 4.0;
  static const xs = 6.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
  static const xxxl = 32.0;
  static const gutter = 20.0;
  static const cardPadding = 18.0;
}

abstract final class DMRadius {
  static const chip = 6.0;
  static const sticker = 8.0;
  static const tile = 10.0;
  static const button = 14.0;
  static const card = 16.0;
  static const dialog = 18.0;
  static const sheet = 22.0;
}

/// Type roles. Outfit carries the app's language (through the TextTheme);
/// JetBrains Mono carries addresses, amounts and timers; Silkscreen is for
/// short stickers, step counters and taglines only.
abstract final class DMType {
  // Code ligatures off: "->", "..." and "!=" must render as typed in data.
  static const _noLigatures = [
    FontFeature.disable('calt'),
    FontFeature.disable('liga'),
  ];

  static TextStyle mono({
    double size = 14,
    Color color = DM.bone,
    FontWeight weight = FontWeight.w400,
    double spacing = 0,
    double? height,
  }) => GoogleFonts.jetBrainsMono(
    fontSize: size,
    color: color,
    fontWeight: weight,
    letterSpacing: spacing,
    height: height,
    fontFeatures: _noLigatures,
  );

  /// Outfit has no math symbols ("≈" in "≈ 98 SOL"); JetBrains Mono, which
  /// ships beside it, draws them instead of a platform font or a box.
  static final List<String> symbolFallback = [
    GoogleFonts.jetBrainsMono().fontFamily!,
  ];

  static TextStyle outfit({
    double size = 15,
    Color color = DM.bone,
    FontWeight weight = FontWeight.w400,
    double spacing = 0,
    double? height,
  }) => GoogleFonts.outfit(
    fontSize: size,
    color: color,
    fontWeight: weight,
    letterSpacing: spacing,
    height: height,
  ).copyWith(fontFamilyFallback: symbolFallback);

  /// Silkscreen. Uppercase it at the call site; never use it for sentences,
  /// numbers people must read exactly, or anything longer than a few words.
  static TextStyle pixel({
    double size = 11,
    Color color = DM.pulse,
    double spacing = 2,
    FontWeight weight = FontWeight.w400,
    double? height,
  }) => GoogleFonts.silkscreen(
    fontSize: size,
    color: color,
    fontWeight: weight,
    letterSpacing: spacing,
    height: height ?? 1,
  );

  /// Sticker word: "ALIVE", "TIER DUE", "STEP 1/3".
  static TextStyle sticker(Color color, {double size = 10.5}) =>
      pixel(size: size, color: color, spacing: size * 0.24);

  /// "CHECK IN, OR CHECK OUT."
  static TextStyle tagline({double size = 13, Color color = DM.pulse}) =>
      pixel(size: size, color: color, spacing: size * 0.3, height: 1.4);

  /// Uppercase, letter-spaced mono caption: "PLAN", "TIER 2".
  static TextStyle label({Color color = DM.ash, double size = 10.5}) =>
      mono(size: size, color: color, spacing: 1.5);

  /// Mono chip text for dense data tags ("mainnet only").
  static TextStyle chip(Color color) =>
      mono(size: 11.5, color: color, weight: FontWeight.w500, spacing: 0.4);

  /// Amounts, addresses, durations in running text: "0.100 SOL · 0 USDC".
  static TextStyle data({Color color = DM.dust, double size = 13}) =>
      mono(size: size, color: color, height: 1.5);

  /// A single large figure.
  static TextStyle stat({Color color = DM.bone}) =>
      mono(size: 22, color: color);

  /// The ring countdown: "1m 55s".
  static TextStyle countdown(Color color, {double size = 48}) => mono(
    size: size,
    color: color,
    weight: FontWeight.w500,
    spacing: -0.02 * size,
    height: 1.05,
  );
}

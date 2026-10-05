import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Deadman brand tokens (docs/brand/ui-reference/deadman_theme.dart).
abstract final class DM {
  // Surfaces, darkest to lightest.
  static const void_ = Color(0xFF050707); // canvas
  static const graphite = Color(0xFF0F1615); // cards
  static const raise = Color(0xFF141D1C); // icon tiles, chips, inputs
  static const line = Color(0xFF1D2928); // 1px borders, dividers
  static const track = Color(0xFF17211F); // ring track, empty bars
  static const deep = Color(0xFF0B3A36); // selected pill / container

  // The mark.
  static const tide = Color(0xFF1FA597); // lower half of the mark
  static const signal = Color(0xFF54F9E8); // actions + on track

  // Text.
  static const bone = Color(0xFFE8F1F0); // primary text
  static const sub = Color(0xFF8FA3A1); // secondary text
  static const mist = Color(0xFF6F8482); // captions, labels

  // Status: rings, countdowns, chips, time labels. Never whole cards or
  // buttons.
  static const onTrack = signal; // check-in inside its window
  static const attention = Color(0xFFFFB547); // overdue / last 25% of window
  static const due = Color(0xFFFF5D73); // tier due or releasing; panic
  static const locked = Color(0xFFA493FF); // duress / lockdown active
  static const released = sub; // paid, history only
}

enum DMStatus { onTrack, attention, due, locked, released }

extension DMStatusX on DMStatus {
  Color get color => switch (this) {
    DMStatus.onTrack => DM.onTrack,
    DMStatus.attention => DM.attention,
    DMStatus.due => DM.due,
    DMStatus.locked => DM.locked,
    DMStatus.released => DM.released,
  };

  String get label => switch (this) {
    DMStatus.onTrack => 'ON TRACK',
    DMStatus.attention => 'ATTENTION',
    DMStatus.due => 'DUE',
    DMStatus.locked => 'LOCKED',
    DMStatus.released => 'RELEASED',
  };

  /// Chip / icon-tile background: the status color at low opacity.
  Color get tint => color.withValues(alpha: 0.12);
}

/// Countdown status from the remaining share of a window (0..1).
DMStatus statusForWindow(
  double remaining, {
  bool releasing = false,
  bool locked = false,
}) {
  if (locked) return DMStatus.locked;
  if (releasing || remaining <= 0) return DMStatus.due;
  if (remaining <= 0.25) return DMStatus.attention;
  return DMStatus.onTrack;
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
  static const tile = 10.0;
  static const button = 12.0;
  static const card = 14.0;
  static const dialog = 16.0;
  static const sheet = 20.0;
}

/// Type helpers. Outfit carries headings and body (through the TextTheme);
/// JetBrains Mono carries numbers, addresses, amounts, durations and status
/// labels.
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
  );

  /// Uppercase, letter-spaced caption: "DAY STREAK", "BEST".
  static TextStyle label({Color color = DM.mist, double size = 10.5}) =>
      mono(size: size, color: color, spacing: 1.5);

  /// Status chip text.
  static TextStyle chip(Color color) =>
      mono(size: 11, color: color, weight: FontWeight.w500, spacing: 1.3);

  /// Amounts, addresses, durations in running text: "0.100 SOL · 0 USDC".
  static TextStyle data({Color color = DM.sub, double size = 13}) =>
      mono(size: size, color: color, height: 1.5);

  /// Stat tile value.
  static TextStyle stat({Color color = DM.bone}) =>
      mono(size: 22, color: color);

  /// The ring countdown: "1m 49s".
  static TextStyle countdown(Color color, {double size = 44}) =>
      mono(size: size, color: color, spacing: -1);
}

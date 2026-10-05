import 'package:flutter/material.dart';

import 'theme/deadman_theme.dart';
import 'theme/tokens.dart';

export 'theme/deadman_theme.dart';
export 'theme/tokens.dart';

/// Pre-brand color names, mapped onto the [DM] tokens so screens keep
/// compiling while they migrate.
@Deprecated('Use DM tokens and DMStatus from theme/tokens.dart')
abstract final class DmColors {
  static const bg = DM.void_;
  static const surface = DM.graphite;
  static const raised = DM.raise;
  static const line = DM.line;
  static const text = DM.bone;
  static const muted = DM.sub;
  static const alive = DM.signal;
  static const warn = DM.attention;
  static const danger = DM.due;

  /// Was a purple "Plus" accent. The brand has one accent; purple is
  /// reserved for [DMStatus.locked].
  static const plus = DM.tide;
}

ThemeData buildTheme() => DeadmanTheme.dark();

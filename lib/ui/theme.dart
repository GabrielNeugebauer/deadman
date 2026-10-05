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
  static const surface = DM.grave;
  static const raised = DM.raise;
  static const line = DM.line;
  static const text = DM.bone;
  static const muted = DM.dust;
  static const alive = DM.pulse;
  static const warn = DM.missed;
  static const danger = DM.flatline;

  /// Was a purple "Plus" accent. The brand has one accent, Pulse.
  static const plus = DM.pulse;
}

ThemeData buildTheme() => DeadmanTheme.dark();

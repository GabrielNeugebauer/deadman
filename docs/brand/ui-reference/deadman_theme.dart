// Deadman app theme. Drop into lib/ui/theme/ and wire with MaterialApp(theme: DeadmanTheme.dark()).
// Fonts: add google_fonts to pubspec.yaml (Outfit + JetBrains Mono).
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class DM {
  // Brand
  static const void_ = Color(0xFF050707);
  static const graphite = Color(0xFF0F1615); // cards
  static const raise = Color(0xFF141D1C);    // icon tiles, chips
  static const line = Color(0xFF1D2928);     // borders, dividers
  static const track = Color(0xFF17211F);    // ring track
  static const deep = Color(0xFF0B3A36);     // active nav pill
  static const tide = Color(0xFF1FA597);     // lower half of the mark
  static const signal = Color(0xFF54F9E8);   // actions + "on track"
  static const bone = Color(0xFFE8F1F0);     // text
  static const sub = Color(0xFF8FA3A1);      // secondary text, "released"
  static const mist = Color(0xFF6F8482);     // captions

  // Status (rings, countdowns, chips, time labels; never whole cards or buttons)
  static const onTrack = signal;                 // check-in inside its window
  static const attention = Color(0xFFFFB547);    // check-in overdue / last 25% of a window
  static const due = Color(0xFFFF5D73);          // tier due or releasing; panic lockdown
  static const locked = Color(0xFFA493FF);       // duress PIN / lockdown active
  static const released = sub;                   // paid, history only
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
  /// Chip background: the status color at low opacity.
  Color get tint => color.withOpacity(this == DMStatus.released ? 0.12 : 0.12);
}

/// Picks the countdown status from the remaining share of a window (0..1).
DMStatus statusForWindow(double remaining, {bool releasing = false, bool locked = false}) {
  if (locked) return DMStatus.locked;
  if (releasing || remaining <= 0) return DMStatus.due;
  if (remaining <= 0.25) return DMStatus.attention;
  return DMStatus.onTrack;
}

class DeadmanTheme {
  static TextStyle mono({double size = 14, Color color = DM.bone, double spacing = 0}) =>
      GoogleFonts.jetBrainsMono(fontSize: size, color: color, letterSpacing: spacing);

  static ThemeData dark() {
    final text = GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme).apply(bodyColor: DM.bone, displayColor: DM.bone);
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: DM.void_,
      colorScheme: const ColorScheme.dark(
        primary: DM.signal, onPrimary: DM.void_,
        secondary: DM.tide, onSecondary: DM.void_,
        surface: DM.graphite, onSurface: DM.bone,
        error: DM.due, onError: DM.void_,
        outline: DM.line,
      ),
      textTheme: text.copyWith(
        headlineMedium: text.headlineMedium?.copyWith(fontSize: 30, fontWeight: FontWeight.w700, letterSpacing: -0.9),
        titleLarge: text.titleLarge?.copyWith(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.4),
        bodyMedium: text.bodyMedium?.copyWith(fontSize: 15, color: DM.sub, height: 1.45),
      ),
      cardTheme: CardTheme(
        color: DM.graphite, elevation: 0, margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: DM.line)),
      ),
      dividerTheme: const DividerThemeData(color: DM.line, thickness: 1, space: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: DM.signal, foregroundColor: DM.void_, minimumSize: const Size.fromHeight(56),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: GoogleFonts.outfit(fontSize: 17, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: DM.bone, minimumSize: const Size.fromHeight(48), side: const BorderSide(color: DM.line),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: DM.signal)),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: DM.void_, indicatorColor: DM.deep, surfaceTintColor: Colors.transparent,
        iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(color: s.contains(WidgetState.selected) ? DM.signal : DM.mist)),
        labelTextStyle: WidgetStateProperty.resolveWith((s) => GoogleFonts.outfit(fontSize: 12, color: s.contains(WidgetState.selected) ? DM.bone : DM.mist)),
      ),
    );
  }
}

/// Status chip: square dot + mono caps label.
class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key, this.text});
  final DMStatus status;
  final String? text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: status.tint, borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 6, height: 6, color: status.color),
          const SizedBox(width: 7),
          Text((text ?? status.label).toUpperCase(), style: DeadmanTheme.mono(size: 11, color: status.color, spacing: 1.3)),
        ]),
      );
}

/// Countdown ring: flat ends, no glow. Dashed when a tier is due.
class CountdownRing extends StatelessWidget {
  const CountdownRing({super.key, required this.progress, required this.status, required this.child, this.size = 236});
  final double progress; // 0..1 remaining
  final DMStatus status;
  final Widget child;
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: size, height: size,
        child: CustomPaint(painter: _RingPainter(progress, status), child: Center(child: child)),
      );
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.p, this.s);
  final double p; final DMStatus s;
  @override
  void paint(Canvas c, Size z) {
    final r = Rect.fromCircle(center: z.center(Offset.zero), radius: z.width / 2 - 8);
    final track = Paint()..style = PaintingStyle.stroke..strokeWidth = 10..color = s == DMStatus.due ? DM.due.withOpacity(.18) : DM.track;
    c.drawArc(r, 0, 6.2832, false, track);
    final arc = Paint()..style = PaintingStyle.stroke..strokeWidth = 10..strokeCap = StrokeCap.butt..color = s.color;
    if (s == DMStatus.due) {
      for (var i = 0; i < 60; i++) { c.drawArc(r, i * 6.2832 / 60, 0.03, false, arc); }
    } else {
      c.drawArc(r, -1.5708, 6.2832 * p.clamp(0, 1), false, arc);
    }
  }
  @override
  bool shouldRepaint(_RingPainter o) => o.p != p || o.s != s;
}

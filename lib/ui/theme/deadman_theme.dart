import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens.dart';

abstract final class DeadmanTheme {
  /// Same as [DMType.mono]; kept for parity with the brand reference file.
  static TextStyle mono({
    double size = 14,
    Color color = DM.bone,
    double spacing = 0,
  }) => DMType.mono(size: size, color: color, spacing: spacing);

  static bool _fontsReady = false;

  /// Outfit, JetBrains Mono and Silkscreen ship in assets/brand/fonts. A
  /// security app makes no request to Google to draw its own text.
  static void _useBundledFonts() {
    if (_fontsReady) return;
    _fontsReady = true;
    GoogleFonts.config.allowRuntimeFetching = false;
    LicenseRegistry.addLicense(() async* {
      for (final (family, file) in const [
        ('Outfit', 'OFL-Outfit.txt'),
        ('JetBrains Mono', 'OFL-JetBrainsMono.txt'),
        ('Silkscreen', 'OFL-Silkscreen.txt'),
      ]) {
        final text = await rootBundle.loadString('assets/brand/fonts/$file');
        yield LicenseEntryWithLineBreaks([family], text);
      }
    });
  }

  static const _scheme = ColorScheme.dark(
    primary: DM.pulse,
    onPrimary: DM.void_,
    primaryContainer: DM.deep,
    onPrimaryContainer: DM.pulse,
    secondary: DM.pulse,
    onSecondary: DM.void_,
    secondaryContainer: DM.deep,
    onSecondaryContainer: DM.pulse,
    tertiary: DM.missed,
    onTertiary: DM.void_,
    tertiaryContainer: Color(0xFF2A2112),
    onTertiaryContainer: DM.missed,
    error: DM.flatline,
    onError: DM.void_,
    errorContainer: Color(0xFF2A1417),
    onErrorContainer: DM.flatline,
    surface: DM.grave,
    onSurface: DM.bone,
    onSurfaceVariant: DM.dust,
    surfaceDim: DM.void_,
    surfaceBright: DM.raise,
    surfaceContainerLowest: DM.void_,
    surfaceContainerLow: DM.pit,
    surfaceContainer: DM.grave,
    surfaceContainerHigh: DM.raise,
    surfaceContainerHighest: DM.raise,
    outline: DM.seam,
    outlineVariant: DM.line,
    inverseSurface: DM.bone,
    onInverseSurface: DM.void_,
    inversePrimary: DM.deep,
    surfaceTint: Colors.transparent,
    shadow: Colors.black,
    scrim: Color(0xCC0A0B0D),
  );

  static ThemeData dark() {
    _useBundledFonts();
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: _scheme,
    );
    final outfit = GoogleFonts.outfitTextTheme(base.textTheme).apply(
      bodyColor: DM.bone,
      displayColor: DM.bone,
      fontFamilyFallback: DMType.symbolFallback,
    );
    final text = outfit.copyWith(
      displayLarge: outfit.displayLarge?.copyWith(
        fontSize: 44,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.6,
        height: 1.05,
      ),
      displayMedium: outfit.displayMedium?.copyWith(
        fontSize: 38,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.3,
        height: 1.1,
      ),
      displaySmall: outfit.displaySmall?.copyWith(
        fontSize: 34,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.1,
        height: 1.1,
      ),
      headlineLarge: outfit.headlineLarge?.copyWith(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.0,
        height: 1.15,
      ),
      headlineMedium: outfit.headlineMedium?.copyWith(
        fontSize: 30,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.9,
        height: 1.15,
      ),
      headlineSmall: outfit.headlineSmall?.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
        height: 1.2,
      ),
      titleLarge: outfit.titleLarge?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
        height: 1.25,
      ),
      titleMedium: outfit.titleMedium?.copyWith(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        height: 1.3,
      ),
      titleSmall: outfit.titleSmall?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
        height: 1.3,
      ),
      bodyLarge: outfit.bodyLarge?.copyWith(
        fontSize: 16,
        letterSpacing: 0,
        height: 1.45,
      ),
      bodyMedium: outfit.bodyMedium?.copyWith(
        fontSize: 15,
        color: DM.dust,
        letterSpacing: 0,
        height: 1.45,
      ),
      bodySmall: outfit.bodySmall?.copyWith(
        fontSize: 13,
        color: DM.ash,
        letterSpacing: 0,
        height: 1.4,
      ),
      labelLarge: outfit.labelLarge?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      labelMedium: outfit.labelMedium?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
      ),
      labelSmall: outfit.labelSmall?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: DM.ash,
        letterSpacing: 0.2,
      ),
    );

    const lineSide = BorderSide(color: DM.line);
    RoundedRectangleBorder rounded(double r, {BorderSide side = lineSide}) =>
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(r),
          side: side,
        );
    OutlineInputBorder inputBorder(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(DMRadius.button),
          borderSide: BorderSide(color: color, width: width),
        );
    bool selected(Set<WidgetState> s) => s.contains(WidgetState.selected);
    bool disabled(Set<WidgetState> s) => s.contains(WidgetState.disabled);

    return base.copyWith(
      scaffoldBackgroundColor: DM.void_,
      canvasColor: DM.void_,
      dividerColor: DM.line,
      splashFactory: InkRipple.splashFactory,
      textTheme: text,
      primaryTextTheme: text,
      iconTheme: const IconThemeData(color: DM.bone, size: 22),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: DM.pulse,
        selectionColor: DM.pulse.withValues(alpha: 0.28),
        selectionHandleColor: DM.pulse,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: DM.void_,
        foregroundColor: DM.bone,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        // Titles line up with the 20px screen gutter.
        titleSpacing: DMSpace.gutter,
        titleTextStyle: text.titleLarge,
        systemOverlayStyle: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: DM.void_,
        ),
      ),
      cardTheme: CardThemeData(
        color: DM.grave,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: rounded(DMRadius.card),
      ),
      dividerTheme: const DividerThemeData(
        color: DM.line,
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size.fromHeight(56)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 20),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(DMRadius.button),
            ),
          ),
          elevation: const WidgetStatePropertyAll(0),
          textStyle: WidgetStatePropertyAll(
            DMType.outfit(size: 17, weight: FontWeight.w600),
          ),
          iconSize: const WidgetStatePropertyAll(22),
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => disabled(s) ? DM.raise : DM.pulse,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => disabled(s) ? DM.ash : DM.void_,
          ),
          overlayColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.pressed)
                ? DM.void_.withValues(alpha: 0.12)
                : DM.void_.withValues(alpha: 0.06),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 16),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(DMRadius.button),
            ),
          ),
          side: const WidgetStatePropertyAll(lineSide),
          textStyle: WidgetStatePropertyAll(
            DMType.outfit(size: 15, weight: FontWeight.w600),
          ),
          iconSize: const WidgetStatePropertyAll(18),
          backgroundColor: const WidgetStatePropertyAll(DM.grave),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => disabled(s) ? DM.ash : DM.bone,
          ),
          overlayColor: WidgetStatePropertyAll(DM.bone.withValues(alpha: 0.06)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: DM.pulse,
          disabledForegroundColor: DM.ash,
          textStyle: DMType.outfit(size: 15, weight: FontWeight.w500),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DMRadius.tile),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: DM.bone,
          disabledForegroundColor: DM.ash,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: DM.pulse,
        foregroundColor: DM.void_,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DMRadius.card),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: DM.void_,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 72,
        indicatorColor: DM.deep,
        indicatorShape: const StadiumBorder(),
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: selected(s) ? DM.pulse : DM.ash),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => DMType.outfit(
            size: 12.5,
            weight: selected(s) ? FontWeight.w600 : FontWeight.w500,
            color: selected(s) ? DM.bone : DM.ash,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: DM.void_,
        indicatorColor: DM.deep,
        selectedIconTheme: const IconThemeData(color: DM.pulse),
        unselectedIconTheme: const IconThemeData(color: DM.ash),
        selectedLabelTextStyle: DMType.outfit(size: 12.5, color: DM.bone),
        unselectedLabelTextStyle: DMType.outfit(size: 12.5, color: DM.ash),
      ),
      tabBarTheme: TabBarThemeData(
        indicatorColor: DM.pulse,
        dividerColor: DM.line,
        labelColor: DM.bone,
        unselectedLabelColor: DM.ash,
        labelStyle: DMType.outfit(size: 15, weight: FontWeight.w600),
        unselectedLabelStyle: DMType.outfit(size: 15, weight: FontWeight.w500),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: DM.raise,
        selectedColor: DM.deep,
        disabledColor: DM.grave,
        checkmarkColor: DM.pulse,
        side: lineSide,
        shape: rounded(DMRadius.chip),
        labelStyle: DMType.outfit(size: 13, weight: FontWeight.w500),
        secondaryLabelStyle: DMType.outfit(size: 13, color: DM.pulse),
        iconTheme: const IconThemeData(color: DM.bone, size: 16),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => selected(s) ? DM.deep : DM.grave,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => disabled(s)
                ? DM.ash
                : selected(s)
                ? DM.pulse
                : DM.dust,
          ),
          iconColor: WidgetStateProperty.resolveWith(
            (s) => selected(s) ? DM.pulse : DM.dust,
          ),
          side: const WidgetStatePropertyAll(lineSide),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(DMRadius.tile),
            ),
          ),
          textStyle: WidgetStatePropertyAll(
            DMType.outfit(size: 14, weight: FontWeight.w600),
          ),
          overlayColor: WidgetStatePropertyAll(
            DM.pulse.withValues(alpha: 0.06),
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => disabled(s)
              ? DM.line
              : selected(s)
              ? DM.void_
              : DM.ash,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => selected(s) ? (disabled(s) ? DM.deep : DM.pulse) : DM.raise,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => selected(s) ? Colors.transparent : DM.line,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => selected(s)
              ? (disabled(s) ? DM.deep : DM.pulse)
              : Colors.transparent,
        ),
        checkColor: const WidgetStatePropertyAll(DM.void_),
        side: WidgetStateBorderSide.resolveWith(
          (s) => selected(s)
              ? BorderSide.none
              : BorderSide(color: disabled(s) ? DM.line : DM.dust, width: 1.5),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => disabled(s)
              ? DM.line
              : selected(s)
              ? DM.pulse
              : DM.dust,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: DM.pulse,
        inactiveTrackColor: DM.line,
        thumbColor: DM.pulse,
        overlayColor: DM.pulse.withValues(alpha: 0.12),
        valueIndicatorColor: DM.raise,
        valueIndicatorTextStyle: DMType.mono(size: 13),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: DM.pulse,
        linearTrackColor: DM.line,
        circularTrackColor: Colors.transparent,
        linearMinHeight: 4,
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: DM.pit,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: inputBorder(DM.seam),
        enabledBorder: inputBorder(DM.seam),
        disabledBorder: inputBorder(DM.line),
        focusedBorder: inputBorder(DM.pulse, 1.5),
        errorBorder: inputBorder(DM.flatline),
        focusedErrorBorder: inputBorder(DM.flatline, 1.5),
        labelStyle: DMType.outfit(size: 15, color: DM.dust),
        floatingLabelStyle: WidgetStateTextStyle.resolveWith(
          (s) => DMType.outfit(
            size: 14,
            color: s.contains(WidgetState.error)
                ? DM.flatline
                : s.contains(WidgetState.focused)
                ? DM.pulse
                : DM.dust,
          ),
        ),
        hintStyle: DMType.outfit(size: 15, color: DM.ash),
        helperStyle: DMType.outfit(size: 13, color: DM.ash),
        errorStyle: DMType.outfit(size: 13, color: DM.flatline),
        prefixIconColor: DM.dust,
        suffixIconColor: DM.dust,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: DM.grave,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: rounded(DMRadius.dialog),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium,
        barrierColor: const Color(0xCC0A0B0D),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: DM.grave,
        modalBackgroundColor: DM.grave,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        dragHandleColor: DM.line,
        modalBarrierColor: Color(0xCC0A0B0D),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(DMRadius.sheet),
          ),
          side: BorderSide(color: DM.line),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: DM.raise,
        elevation: 0,
        contentTextStyle: DMType.outfit(size: 14, color: DM.bone),
        actionTextColor: DM.pulse,
        closeIconColor: DM.dust,
        shape: rounded(DMRadius.button),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: DM.dust,
        textColor: DM.bone,
        titleTextStyle: DMType.outfit(size: 16, weight: FontWeight.w600),
        subtitleTextStyle: DMType.outfit(size: 14, color: DM.dust),
        leadingAndTrailingTextStyle: DMType.mono(size: 13, color: DM.dust),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        minVerticalPadding: 12,
      ),
      expansionTileTheme: const ExpansionTileThemeData(
        iconColor: DM.dust,
        collapsedIconColor: DM.dust,
        textColor: DM.bone,
        collapsedTextColor: DM.bone,
        shape: Border(),
        collapsedShape: Border(),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: DM.grave,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: rounded(DMRadius.button),
        textStyle: DMType.outfit(size: 15),
      ),
      menuTheme: const MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(DM.grave),
          surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
          elevation: WidgetStatePropertyAll(0),
          side: WidgetStatePropertyAll(lineSide),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: DM.raise,
          borderRadius: BorderRadius.circular(DMRadius.chip),
          border: Border.all(color: DM.line),
        ),
        textStyle: DMType.outfit(size: 13),
      ),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: DM.grave,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: rounded(DMRadius.dialog),
        headerBackgroundColor: DM.grave,
        headerForegroundColor: DM.bone,
        dividerColor: DM.line,
        todayBorder: const BorderSide(color: DM.pulse),
      ),
      timePickerTheme: TimePickerThemeData(
        backgroundColor: DM.grave,
        elevation: 0,
        shape: rounded(DMRadius.dialog),
        dialBackgroundColor: DM.raise,
        hourMinuteColor: DM.raise,
        dayPeriodBorderSide: lineSide,
      ),
      badgeTheme: BadgeThemeData(
        backgroundColor: DM.pulse,
        textColor: DM.void_,
        textStyle: DMType.mono(size: 10.5, weight: FontWeight.w700),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(DM.dust.withValues(alpha: 0.4)),
        radius: const Radius.circular(4),
      ),
    );
  }
}

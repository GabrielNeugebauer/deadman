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

  /// Outfit and JetBrains Mono ship in assets/brand/fonts. A security app
  /// makes no request to Google to draw its own text.
  static void _useBundledFonts() {
    if (_fontsReady) return;
    _fontsReady = true;
    GoogleFonts.config.allowRuntimeFetching = false;
    LicenseRegistry.addLicense(() async* {
      for (final (family, file) in const [
        ('Outfit', 'OFL-Outfit.txt'),
        ('JetBrains Mono', 'OFL-JetBrainsMono.txt'),
      ]) {
        final text = await rootBundle.loadString('assets/brand/fonts/$file');
        yield LicenseEntryWithLineBreaks([family], text);
      }
    });
  }

  static const _scheme = ColorScheme.dark(
    primary: DM.signal,
    onPrimary: DM.void_,
    primaryContainer: DM.deep,
    onPrimaryContainer: DM.signal,
    secondary: DM.tide,
    onSecondary: DM.void_,
    secondaryContainer: DM.deep,
    onSecondaryContainer: DM.signal,
    tertiary: DM.tide,
    onTertiary: DM.void_,
    tertiaryContainer: DM.deep,
    onTertiaryContainer: DM.signal,
    error: DM.due,
    onError: DM.void_,
    errorContainer: Color(0xFF3A1820),
    onErrorContainer: DM.due,
    surface: DM.graphite,
    onSurface: DM.bone,
    onSurfaceVariant: DM.sub,
    surfaceDim: DM.void_,
    surfaceBright: DM.raise,
    surfaceContainerLowest: DM.void_,
    surfaceContainerLow: DM.graphite,
    surfaceContainer: DM.graphite,
    surfaceContainerHigh: DM.raise,
    surfaceContainerHighest: DM.raise,
    outline: DM.line,
    outlineVariant: DM.line,
    inverseSurface: DM.bone,
    onInverseSurface: DM.void_,
    inversePrimary: DM.deep,
    surfaceTint: Colors.transparent,
    shadow: Colors.black,
    scrim: Color(0xCC050707),
  );

  static ThemeData dark() {
    _useBundledFonts();
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: _scheme,
    );
    final outfit = GoogleFonts.outfitTextTheme(base.textTheme)
        .apply(bodyColor: DM.bone, displayColor: DM.bone);
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
        color: DM.sub,
        letterSpacing: 0,
        height: 1.45,
      ),
      bodySmall: outfit.bodySmall?.copyWith(
        fontSize: 13,
        color: DM.mist,
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
        color: DM.mist,
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
        cursorColor: DM.signal,
        selectionColor: DM.signal.withValues(alpha: 0.28),
        selectionHandleColor: DM.signal,
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
        color: DM.graphite,
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
            DMType.outfit(size: 17, weight: FontWeight.w700),
          ),
          iconSize: const WidgetStatePropertyAll(20),
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => disabled(s) ? DM.raise : DM.signal,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => disabled(s) ? DM.mist : DM.void_,
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
          backgroundColor: const WidgetStatePropertyAll(DM.graphite),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => disabled(s) ? DM.mist : DM.bone,
          ),
          overlayColor: WidgetStatePropertyAll(DM.bone.withValues(alpha: 0.06)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: DM.signal,
          disabledForegroundColor: DM.mist,
          textStyle: DMType.outfit(size: 15, weight: FontWeight.w500),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DMRadius.tile),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: DM.bone,
          disabledForegroundColor: DM.mist,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: DM.signal,
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
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DMRadius.tile),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: selected(s) ? DM.signal : DM.mist),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => DMType.outfit(
            size: 12.5,
            weight: FontWeight.w500,
            color: selected(s) ? DM.bone : DM.mist,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: DM.void_,
        indicatorColor: DM.deep,
        selectedIconTheme: const IconThemeData(color: DM.signal),
        unselectedIconTheme: const IconThemeData(color: DM.mist),
        selectedLabelTextStyle: DMType.outfit(size: 12.5, color: DM.bone),
        unselectedLabelTextStyle: DMType.outfit(size: 12.5, color: DM.mist),
      ),
      tabBarTheme: TabBarThemeData(
        indicatorColor: DM.signal,
        dividerColor: DM.line,
        labelColor: DM.bone,
        unselectedLabelColor: DM.mist,
        labelStyle: DMType.outfit(size: 15, weight: FontWeight.w600),
        unselectedLabelStyle: DMType.outfit(size: 15, weight: FontWeight.w500),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: DM.raise,
        selectedColor: DM.deep,
        disabledColor: DM.graphite,
        checkmarkColor: DM.signal,
        side: lineSide,
        shape: rounded(DMRadius.chip),
        labelStyle: DMType.outfit(size: 13, weight: FontWeight.w500),
        secondaryLabelStyle: DMType.outfit(size: 13, color: DM.signal),
        iconTheme: const IconThemeData(color: DM.bone, size: 16),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => selected(s) ? DM.deep : DM.graphite,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => disabled(s)
                ? DM.mist
                : selected(s)
                ? DM.signal
                : DM.sub,
          ),
          iconColor: WidgetStateProperty.resolveWith(
            (s) => selected(s) ? DM.signal : DM.sub,
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
            DM.signal.withValues(alpha: 0.06),
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => disabled(s)
              ? DM.line
              : selected(s)
              ? DM.void_
              : DM.mist,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => selected(s) ? (disabled(s) ? DM.deep : DM.signal) : DM.raise,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => selected(s) ? Colors.transparent : DM.line,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => selected(s)
              ? (disabled(s) ? DM.deep : DM.signal)
              : Colors.transparent,
        ),
        checkColor: const WidgetStatePropertyAll(DM.void_),
        side: WidgetStateBorderSide.resolveWith(
          (s) => selected(s)
              ? BorderSide.none
              : BorderSide(color: disabled(s) ? DM.line : DM.sub, width: 1.5),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => disabled(s)
              ? DM.line
              : selected(s)
              ? DM.signal
              : DM.sub,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: DM.signal,
        inactiveTrackColor: DM.track,
        thumbColor: DM.signal,
        overlayColor: DM.signal.withValues(alpha: 0.12),
        valueIndicatorColor: DM.raise,
        valueIndicatorTextStyle: DMType.mono(size: 13),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: DM.signal,
        linearTrackColor: DM.track,
        circularTrackColor: Colors.transparent,
        linearMinHeight: 4,
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: DM.raise,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: inputBorder(DM.line),
        enabledBorder: inputBorder(DM.line),
        disabledBorder: inputBorder(DM.line),
        focusedBorder: inputBorder(DM.signal, 1.5),
        errorBorder: inputBorder(DM.due),
        focusedErrorBorder: inputBorder(DM.due, 1.5),
        labelStyle: DMType.outfit(size: 15, color: DM.sub),
        floatingLabelStyle: WidgetStateTextStyle.resolveWith(
          (s) => DMType.outfit(
            size: 14,
            color: s.contains(WidgetState.error)
                ? DM.due
                : s.contains(WidgetState.focused)
                ? DM.signal
                : DM.sub,
          ),
        ),
        hintStyle: DMType.outfit(size: 15, color: DM.sub),
        helperStyle: DMType.outfit(size: 13, color: DM.mist),
        errorStyle: DMType.outfit(size: 13, color: DM.due),
        prefixIconColor: DM.sub,
        suffixIconColor: DM.sub,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: DM.graphite,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: rounded(DMRadius.dialog),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium,
        barrierColor: const Color(0xCC050707),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: DM.graphite,
        modalBackgroundColor: DM.graphite,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        dragHandleColor: DM.line,
        modalBarrierColor: Color(0xCC050707),
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
        actionTextColor: DM.signal,
        closeIconColor: DM.sub,
        shape: rounded(DMRadius.button),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: DM.sub,
        textColor: DM.bone,
        titleTextStyle: DMType.outfit(size: 16, weight: FontWeight.w600),
        subtitleTextStyle: DMType.outfit(size: 14, color: DM.sub),
        leadingAndTrailingTextStyle: DMType.mono(size: 13, color: DM.sub),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        minVerticalPadding: 12,
      ),
      expansionTileTheme: const ExpansionTileThemeData(
        iconColor: DM.sub,
        collapsedIconColor: DM.sub,
        textColor: DM.bone,
        collapsedTextColor: DM.bone,
        shape: Border(),
        collapsedShape: Border(),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: DM.graphite,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: rounded(DMRadius.button),
        textStyle: DMType.outfit(size: 15),
      ),
      menuTheme: const MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(DM.graphite),
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
        backgroundColor: DM.graphite,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: rounded(DMRadius.dialog),
        headerBackgroundColor: DM.graphite,
        headerForegroundColor: DM.bone,
        dividerColor: DM.line,
        todayBorder: const BorderSide(color: DM.signal),
      ),
      timePickerTheme: TimePickerThemeData(
        backgroundColor: DM.graphite,
        elevation: 0,
        shape: rounded(DMRadius.dialog),
        dialBackgroundColor: DM.raise,
        hourMinuteColor: DM.raise,
        dayPeriodBorderSide: lineSide,
      ),
      badgeTheme: const BadgeThemeData(
        backgroundColor: DM.signal,
        textColor: DM.void_,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(DM.sub.withValues(alpha: 0.4)),
        radius: const Radius.circular(4),
      ),
    );
  }
}

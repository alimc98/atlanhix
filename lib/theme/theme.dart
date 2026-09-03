import 'package:flutter/material.dart';

/// NEXUS semantic design tokens (design/COLORS.md). Widgets never use raw
/// colors — everything resolves through [NexusColors] of the active theme.
class NexusColors {
  const NexusColors({
    required this.background,
    required this.surface,
    required this.surfaceElevated,
    required this.surfaceSunken,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
    required this.accentSoft,
    required this.success,
    required this.warning,
    required this.error,
    required this.info,
    required this.border,
    required this.borderStrong,
    required this.overlayScrim,
  });

  final Color background;
  final Color surface;
  final Color surfaceElevated;
  final Color surfaceSunken;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color accent;
  final Color accentSoft;
  final Color success;
  final Color warning;
  final Color error;
  final Color info;
  final Color border;
  final Color borderStrong;
  final Color overlayScrim;

  static const dark = NexusColors(
    background: Color(0xFF0B0F14),
    surface: Color(0xFF111820),
    surfaceElevated: Color(0xFF1A2430),
    surfaceSunken: Color(0xFF080C10),
    textPrimary: Color(0xFFE8EEF5),
    textSecondary: Color(0xFF9AA7B4),
    textMuted: Color(0xFF5C6B7A),
    accent: Color(0xFF4F8CFF),
    accentSoft: Color(0x244F8CFF),
    success: Color(0xFF34D399),
    warning: Color(0xFFFBBF24),
    error: Color(0xFFF87171),
    info: Color(0xFF38BDF8),
    border: Color(0x12FFFFFF),
    borderStrong: Color(0x24FFFFFF),
    overlayScrim: Color(0x8C000000),
  );

  static const oled = NexusColors(
    background: Color(0xFF000000),
    surface: Color(0xFF0A0A0C),
    surfaceElevated: Color(0xFF131318),
    surfaceSunken: Color(0xFF000000),
    textPrimary: Color(0xFFE8EEF5),
    textSecondary: Color(0xFF9AA7B4),
    textMuted: Color(0xFF5C6B7A),
    accent: Color(0xFF4F8CFF),
    accentSoft: Color(0x244F8CFF),
    success: Color(0xFF34D399),
    warning: Color(0xFFFBBF24),
    error: Color(0xFFF87171),
    info: Color(0xFF38BDF8),
    border: Color(0x1FFFFFFF),
    borderStrong: Color(0x33FFFFFF),
    overlayScrim: Color(0xB3000000),
  );

  static const light = NexusColors(
    background: Color(0xFFF6F8FA),
    surface: Color(0xFFFFFFFF),
    surfaceElevated: Color(0xFFFFFFFF),
    surfaceSunken: Color(0xFFEEF2F6),
    textPrimary: Color(0xFF0B1220),
    textSecondary: Color(0xFF47536B),
    textMuted: Color(0xFF8A94A6),
    accent: Color(0xFF2563EB),
    accentSoft: Color(0x1A2563EB),
    success: Color(0xFF059669),
    warning: Color(0xFFB45309),
    error: Color(0xFFDC2626),
    info: Color(0xFF0284C7),
    border: Color(0x140B1220),
    borderStrong: Color(0x290B1220),
    overlayScrim: Color(0x52000000),
  );
}

enum NexusThemeMode { dark, light, oled }

/// v0.3.0 branding alias — new code should use [AtlanhixThemeMode].
typedef AtlanhixThemeMode = NexusThemeMode;

/// Typography scale (design/TYPOGRAPHY.md).
class NexusTypography {
  static const _fontLatin = 'Inter';
  static const _fontFa = 'Vazirmatn';
  static const _mono = 'JetBrainsMono';

  static TextTheme build(Brightness brightness, {String? locale}) {
    final color = brightness == Brightness.dark
        ? NexusColors.dark.textPrimary
        : NexusColors.light.textPrimary;
    final fa = locale?.startsWith('fa') == true;
    final family = fa ? _fontFa : _fontLatin;
    final base = TextTheme(
      displayLarge: TextStyle(
          fontSize: 32,
          height: 40 / 32,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.5),
      titleLarge: TextStyle(
          fontSize: 20, height: 28 / 20, fontWeight: FontWeight.w600),
      titleMedium: TextStyle(
          fontSize: 16, height: 24 / 16, fontWeight: FontWeight.w600),
      bodyLarge: TextStyle(
          fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w400),
      bodyMedium: TextStyle(
          fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w500),
      bodySmall: TextStyle(
          fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w500),
      labelSmall: TextStyle(
          fontSize: 11,
          height: 14 / 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.7),
    );
    return base.apply(
      fontFamily: family,
      fontFamilyFallback: fa ? [_fontLatin, _mono] : [_fontFa, _mono],
      displayColor: color,
      bodyColor: color,
    );
  }

  static const monoStyle = TextStyle(fontFamily: _mono);
}

/// Builds the MaterialApp themes from tokens.
class NexusTheme {
  static ThemeData theme(NexusThemeMode mode, {String? locale}) {
    final c = switch (mode) {
      NexusThemeMode.dark => NexusColors.dark,
      NexusThemeMode.oled => NexusColors.oled,
      NexusThemeMode.light => NexusColors.light,
    };
    final brightness =
        mode == NexusThemeMode.light ? Brightness.light : Brightness.dark;
    final text = NexusTypography.build(brightness, locale: locale);
    final ext = ThemeExt.fromColors(c);
    return ThemeData(
      useMaterial3: true,
      extensions: [ext],
      brightness: brightness,
      scaffoldBackgroundColor: c.background,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: c.accent,
        onPrimary: Colors.white,
        secondary: c.info,
        onSecondary: Colors.black,
        surface: c.surface,
        onSurface: c.textPrimary,
        error: c.error,
        onError: Colors.white,
        surfaceContainerHighest: c.surfaceElevated,
        outline: c.borderStrong,
        outlineVariant: c.border,
      ),
      textTheme: text,
      cardTheme: CardThemeData(
        color: c.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NexusSpacing.radiusCard),
          side: BorderSide(color: c.border),
        ),
        margin: EdgeInsets.zero,
      ),
      dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surfaceSunken,
        hintStyle: text.bodyLarge?.copyWith(color: c.textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(NexusSpacing.radiusInput),
          borderSide: BorderSide(color: c.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(NexusSpacing.radiusInput),
          borderSide: BorderSide(color: c.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(NexusSpacing.radiusInput),
          borderSide: BorderSide(color: c.accent, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.accent,
          foregroundColor: Colors.white,
          textStyle: text.bodyMedium,
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(NexusSpacing.radiusInput),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.textPrimary,
          side: BorderSide(color: c.borderStrong),
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(NexusSpacing.radiusInput),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: c.accent),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: c.accentSoft,
        labelStyle: text.bodySmall?.copyWith(color: c.accent),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NexusSpacing.radiusChip),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: c.surface,
        indicatorColor: c.accentSoft,
        labelTextStyle: WidgetStatePropertyAll(text.bodySmall),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: c.surface,
        selectedIconTheme: IconThemeData(color: c.accent),
        selectedLabelTextStyle: text.bodyMedium?.copyWith(color: c.accent),
        unselectedLabelTextStyle: text.bodyMedium?.copyWith(color: c.textMuted),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surfaceElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NexusSpacing.radiusCard),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.surfaceElevated,
        contentTextStyle: text.bodyMedium,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NexusSpacing.radiusInput),
        ),
      ),
    );
  }
}

/// Spacing / radius constants (4-pt grid).
class NexusSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;

  static const radiusCard = 16.0;
  static const radiusSheet = 24.0;
  static const radiusChip = 8.0;
  static const radiusInput = 12.0;
}

/// Widget-tree accessor for the semantic tokens (resolved per theme).
class ThemeExt extends ThemeExtension<ThemeExt> {
  const ThemeExt({
    required this.accent,
    required this.info,
    required this.success,
    required this.error,
    required this.warning,
    required this.surface,
    required this.surfaceElevated,
    required this.surfaceSunken,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.border,
    required this.accentSoft,
  });

  final Color accent;
  final Color info;
  final Color success;
  final Color error;
  final Color warning;
  final Color surface;
  final Color surfaceElevated;
  final Color surfaceSunken;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color border;
  final Color accentSoft;

  factory ThemeExt.fromColors(NexusColors c) => ThemeExt(
        accent: c.accent,
        info: c.info,
        success: c.success,
        error: c.error,
        warning: c.warning,
        surface: c.surface,
        surfaceElevated: c.surfaceElevated,
        surfaceSunken: c.surfaceSunken,
        textPrimary: c.textPrimary,
        textSecondary: c.textSecondary,
        textMuted: c.textMuted,
        border: c.border,
        accentSoft: c.accentSoft,
      );

  static ThemeExt of(BuildContext c) =>
      Theme.of(c).extension<ThemeExt>() ?? ThemeExt.fromColors(NexusColors.dark);

  @override
  ThemeExt copyWith() => this;

  @override
  ThemeExt lerp(ThemeExtension<ThemeExt>? other, double t) => this;
}

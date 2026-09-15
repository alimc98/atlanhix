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

  // v0.4.2 "line-type" design language (user mockup): near-black matte page,
  // charcoal frosted surfaces, cool off-white ink, mint/lavender as the only
  // accent pair, hairline borders.
  static const dark = NexusColors(
    background: Color(0xFF0A0B0E),
    surface: Color(0xFF1C1F26),
    surfaceElevated: Color(0xFF242832),
    surfaceSunken: Color(0xFF12141A),
    textPrimary: Color(0xFFE8E9ED),
    textSecondary: Color(0xFF9EA3AF),
    textMuted: Color(0xFF7A7E89),
    accent: Color(0xFF4FE0B7),
    accentSoft: Color(0x244FE0B7),
    success: Color(0xFF4FE0B7),
    warning: Color(0xFFE0C34F),
    error: Color(0xFFE86A6A),
    info: Color(0xFF9B6CFF),
    border: Color(0x14FFFFFF),
    borderStrong: Color(0x26FFFFFF),
    overlayScrim: Color(0x8C000000),
  );

  static const oled = NexusColors(
    background: Color(0xFF000000),
    surface: Color(0xFF0B0C0F),
    surfaceElevated: Color(0xFF15171D),
    surfaceSunken: Color(0xFF000000),
    textPrimary: Color(0xFFE8E9ED),
    textSecondary: Color(0xFF9EA3AF),
    textMuted: Color(0xFF7A7E89),
    accent: Color(0xFF4FE0B7),
    accentSoft: Color(0x244FE0B7),
    success: Color(0xFF34D399),
    warning: Color(0xFFFBBF24),
    error: Color(0xFFF87171),
    info: Color(0xFF9B6CFF),
    border: Color(0x1FFFFFFF),
    borderStrong: Color(0x33FFFFFF),
    overlayScrim: Color(0xB3000000),
  );

  static const light = NexusColors(
    background: Color(0xFFF6F8FA),
    surface: Color(0xFFFFFFFF),
    surfaceElevated: Color(0xFFFFFFFF),
    surfaceSunken: Color(0xFFEEF2F6),
    textPrimary: Color(0xFF101216),
    textSecondary: Color(0xFF4A4F5A),
    textMuted: Color(0xFF8A8F9A),
    accent: Color(0xFF0E9E78),
    accentSoft: Color(0x1A0E9E78),
    success: Color(0xFF0E9E78),
    warning: Color(0xFFA8790B),
    error: Color(0xFFC23B3B),
    info: Color(0xFF6D3FD4),
    border: Color(0x140B1220),
    borderStrong: Color(0x290B1220),
    overlayScrim: Color(0x52000000),
  );
}

enum NexusThemeMode { dark, light, oled }

/// v0.3.0 branding alias — new code should use [AtlanhixThemeMode].
typedef AtlanhixThemeMode = NexusThemeMode;

/// v0.3.0 branding alias.
typedef AtlanhixTheme = NexusTheme;

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
    // Persian glyphs must stay cursive-joined: wide tracking would break the
    // shaping, so letter-spacing is Latin-only (mockup headers are LTR caps).
    double ls(double v) => fa ? 0 : v;
    // v0.4.2 mockup typography: geometric sans, section headers ALL-CAPS
    // with wide tracking, big semi-bold metrics, light secondary text.
    final base = TextTheme(
      displayLarge: TextStyle(
          fontSize: 30,
          height: 36 / 30,
          fontWeight: FontWeight.w600,
          letterSpacing: ls(-0.2)),
      titleLarge: TextStyle(
          fontSize: 19,
          height: 26 / 19,
          fontWeight: FontWeight.w500,
          letterSpacing: ls(0.8)),
      titleMedium: TextStyle(
          fontSize: 15,
          height: 20 / 15,
          fontWeight: FontWeight.w500,
          letterSpacing: ls(1.4)),
      bodyLarge: TextStyle(
          fontSize: 14, height: 21 / 14, fontWeight: FontWeight.w400),
      bodyMedium: TextStyle(
          fontSize: 13, height: 19 / 13, fontWeight: FontWeight.w400),
      bodySmall: TextStyle(
          fontSize: 11,
          height: 15 / 11,
          fontWeight: FontWeight.w300,
          letterSpacing: ls(0.2)),
      labelSmall: TextStyle(
          fontSize: 11,
          height: 14 / 11,
          fontWeight: FontWeight.w500,
          letterSpacing: ls(1.6)),
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
        onPrimary: _onAccent(c),
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
      appBarTheme: AppBarTheme(
        backgroundColor: c.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: text.titleLarge,
      ),
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
          foregroundColor: _onAccent(c),
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

/// Mint on dark needs dark ink; the blue it replaced needed white.
Color _onAccent(NexusColors c) =>
    c.accent.computeLuminance() > 0.45 ? const Color(0xFF0A0B0E) : Colors.white;

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

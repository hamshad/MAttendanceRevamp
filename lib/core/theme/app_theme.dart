import 'package:flutter/material.dart';
import 'app_colors.dart';

abstract final class AppTheme {
  static ThemeData get light => _buildTheme(brightness: Brightness.light);
  static ThemeData get dark  => _buildTheme(brightness: Brightness.dark);

  static ThemeData _buildTheme({required Brightness brightness}) {
    final isDark = brightness == Brightness.dark;

    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: brightness,
      primary:    isDark ? AppColors.darkPrimary : AppColors.primary,
      surface:    isDark ? AppColors.darkSurface : AppColors.surface,
      error:      isDark ? AppColors.darkError : AppColors.error,
    ).copyWith(
      onPrimary:  Colors.white,
      outline:    isDark ? AppColors.darkBorder  : AppColors.border,
      surfaceContainerHighest: isDark ? AppColors.darkCard : AppColors.card,
    );

    return ThemeData(
      useMaterial3: true,
      brightness:   brightness,
      colorScheme:  colorScheme,
      fontFamily:   'Roboto',
      scaffoldBackgroundColor: isDark ? AppColors.darkBackground : AppColors.surface,

      // ── Card ────────────────────────────────────────────────────────────
      cardTheme: CardThemeData(
        color: isDark ? AppColors.darkCard : AppColors.card,
        elevation: 1,
        shadowColor: Colors.black.withAlpha(20),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: isDark ? AppColors.darkBorder : AppColors.border,
          ),
        ),
        margin: EdgeInsets.zero,
      ),

      // ── AppBar ──────────────────────────────────────────────────────────
        appBarTheme: AppBarTheme(
          backgroundColor:      isDark ? AppColors.darkCard : AppColors.card,
          foregroundColor:      isDark ? AppColors.darkTextPrimary : AppColors.textPrimary,
          elevation:            0,
          scrolledUnderElevation: 0,
          centerTitle:          false,
          titleTextStyle: TextStyle(
            color:      isDark ? AppColors.darkTextPrimary : AppColors.textPrimary,
            fontSize:   18,
            fontWeight: FontWeight.w600,
            fontFamily: 'Roboto',
          ),
          iconTheme: IconThemeData(
            color: isDark ? AppColors.darkMuted : AppColors.textSecondary,
          ),
        shape: Border(
          bottom: BorderSide(
            color: isDark ? AppColors.darkBorder : AppColors.border,
          ),
        ),
      ),

      // ── Bottom Navigation Bar ────────────────────────────────────────────
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor:     isDark ? AppColors.darkCard : AppColors.card,
        selectedItemColor:   isDark ? AppColors.darkPrimary : AppColors.primary,
        unselectedItemColor: AppColors.gray,
        elevation:           8,
        type:                BottomNavigationBarType.fixed,
        selectedLabelStyle:  const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
        unselectedLabelStyle: const TextStyle(fontSize: 11),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor:       isDark ? AppColors.darkCard : AppColors.card,
        indicatorColor:        isDark ? AppColors.darkPrimary.withAlpha(28) : AppColors.primarySubtle,
        surfaceTintColor:      Colors.transparent,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: isDark ? AppColors.darkPrimary : AppColors.primary,
            );
          }
          return TextStyle(fontSize: 11, color: isDark ? AppColors.darkMuted : AppColors.gray);
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: isDark ? AppColors.darkPrimary : AppColors.primary);
          }
          return const IconThemeData(color: AppColors.gray);
        }),
      ),

      // ── Elevated Button ─────────────────────────────────────────────────
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: isDark ? AppColors.darkPrimary : AppColors.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppColors.gray.withAlpha(80),
          disabledForegroundColor: Colors.white54,
          minimumSize:     const Size(double.infinity, 52),
          shape:           RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          elevation:       0,
          textStyle:       const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: 0),
        ),
      ),

      // ── Outlined Button ─────────────────────────────────────────────────
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: isDark ? AppColors.darkPrimary : AppColors.primary,
          side:            BorderSide(color: isDark ? AppColors.darkBorder : AppColors.border, width: 1.5),
          minimumSize:     const Size(double.infinity, 52),
          shape:           RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle:       const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        ),
      ),

      // ── Text Button ─────────────────────────────────────────────────────
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: isDark ? AppColors.darkPrimary : AppColors.primary,
          textStyle:       const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),

      // ── Input ────────────────────────────────────────────────────────────
      inputDecorationTheme: InputDecorationTheme(
        filled:          true,
        fillColor:       isDark ? AppColors.darkCard : AppColors.card,
        contentPadding:  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide:   const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide:   BorderSide(color: isDark ? AppColors.darkBorder : AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide:   const BorderSide(color: AppColors.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide:   const BorderSide(color: AppColors.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide:   const BorderSide(color: AppColors.error, width: 1.5),
        ),
        hintStyle:  TextStyle(
          color: isDark ? AppColors.darkTextSecondary.withAlpha(160) : AppColors.textSecondary.withAlpha(160),
          fontSize: 14,
        ),
        errorStyle: TextStyle(color: isDark ? AppColors.darkError : AppColors.error, fontSize: 12),
        labelStyle: TextStyle(color: isDark ? AppColors.darkMuted : AppColors.textSecondary),
      ),

      // ── Chip ─────────────────────────────────────────────────────────────
      chipTheme: ChipThemeData(
        backgroundColor: isDark ? AppColors.darkCard : AppColors.graySubtle,
        selectedColor:   isDark ? AppColors.darkPrimary.withAlpha(28) : AppColors.primarySubtle,
        labelStyle:      const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        side:            BorderSide(color: isDark ? AppColors.darkBorder : AppColors.border),
        shape:           RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        padding:         const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        showCheckmark:   false,
      ),

      // ── Divider ──────────────────────────────────────────────────────────
      dividerTheme: DividerThemeData(
        color:     isDark ? AppColors.darkBorder : AppColors.border,
        thickness: 1,
        space:     1,
      ),

      // ── List Tile ────────────────────────────────────────────────────────
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        iconColor:      isDark ? AppColors.darkMuted : AppColors.textSecondary,
        titleTextStyle: TextStyle(
          fontSize:   15,
          fontWeight: FontWeight.w500,
          color:      isDark ? AppColors.darkTextPrimary : AppColors.textPrimary,
        ),
        subtitleTextStyle: TextStyle(
          fontSize: 13,
          color:    isDark ? AppColors.darkTextSecondary : AppColors.textSecondary,
        ),
      ),

      // ── Switch ───────────────────────────────────────────────────────────
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? (isDark ? AppColors.darkPrimary : AppColors.primary)
                : AppColors.gray),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? (isDark ? AppColors.darkPrimary.withAlpha(40) : AppColors.primarySubtle)
                : AppColors.graySubtle),
      ),

      // ── FloatingActionButton ─────────────────────────────────────────────
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: isDark ? AppColors.darkPrimary : AppColors.primary,
        foregroundColor: Colors.white,
        elevation:       4,
        shape:           const CircleBorder(),
      ),

      // ── Text Theme ───────────────────────────────────────────────────────
      textTheme: TextTheme(
        displayLarge:   _ts(28, FontWeight.w700, isDark),
        headlineMedium: _ts(22, FontWeight.w600, isDark),
        titleLarge:     _ts(18, FontWeight.w600, isDark),
        titleMedium:    _ts(15, FontWeight.w600, isDark),
        bodyLarge:      _ts(15, FontWeight.w400, isDark),
        bodyMedium:     _ts(13, FontWeight.w400, isDark),
        bodySmall:      _ts(12, FontWeight.w400, isDark, secondary: true),
        labelLarge:     _ts(13, FontWeight.w500, isDark),
        labelMedium:    _ts(12, FontWeight.w500, isDark),
      ),
    );
  }

  static TextStyle _ts(double size, FontWeight weight, bool isDark, {bool secondary = false}) =>
      TextStyle(
        fontSize:   size,
        fontWeight: weight,
        color:      secondary
            ? (isDark ? AppColors.darkTextSecondary : AppColors.textSecondary)
            : (isDark ? AppColors.darkTextPrimary : AppColors.textPrimary),
      );
}

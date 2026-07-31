import 'package:flutter/material.dart';

abstract final class AppColors {
  // ── Primary (Indigo) ──────────────────────────────────────────────────────
  static const primary       = Color(0xFF4F46E5);
  static const primaryDark   = Color(0xFF4338CA);
  static const primaryDeep   = Color(0xFF3730A3);
  static const primarySubtle = Color(0xFFEEF2FF);

  // ── Surface & Background ──────────────────────────────────────────────────
  static const surface     = Color(0xFFF8FAFC);
  static const card        = Color(0xFFFFFFFF);
  static const border      = Color(0xFFE2E8F0);
  static const borderStrong = Color(0xFFCBD5E1);

  // ── Text ──────────────────────────────────────────────────────────────────
  static const textPrimary   = Color(0xFF0F172A);
  static const textSecondary = Color(0xFF64748B);
  static const textDisabled  = Color(0xFFCBD5E1);

  // ── Semantic: Success (Present, Approved) ─────────────────────────────────
  static const success       = Color(0xFF10B981);
  static const successSubtle = Color(0xFFD1FAE5);

  // ── Semantic: Error (Absent, Rejected) ───────────────────────────────────
  static const error       = Color(0xFFEF4444);
  static const errorSubtle = Color(0xFFFEE2E2);

  // ── Semantic: Warning (Late, Pending) ────────────────────────────────────
  static const warning       = Color(0xFFF59E0B);
  static const warningSubtle = Color(0xFFFEF3C7);

  // ── Semantic: Info (WFH, Holiday) ────────────────────────────────────────
  static const info       = Color(0xFF3B82F6);
  static const infoSubtle = Color(0xFFDBEAFE);

  // ── Semantic: Purple (CompOff, OnDuty, AI) ───────────────────────────────
  static const purple       = Color(0xFF8B5CF6);
  static const purpleSubtle = Color(0xFFEDE9FE);

  // ── Semantic: Orange (HalfDay, Travel) ───────────────────────────────────
  static const orange       = Color(0xFFF97316);
  static const orangeSubtle = Color(0xFFFFEDD5);

  // ── Semantic: Gray (WeekOff, Cancelled) ──────────────────────────────────
  static const gray       = Color(0xFF94A3B8);
  static const graySubtle = Color(0xFFF1F5F9);

  // ── Dark Mode ─────────────────────────────────────────────────────────────
  static const darkBackground   = Color(0xFF0F172A); // Background
  static const darkSurface      = Color(0xFF172033); // Surface (sheets, nav, dialogs)
  static const darkCard         = Color(0xFF1D273B); // Card
  static const darkBorder       = Color(0xFF2C3752); // Border

  static const darkPrimary     = Color(0xFF6366F1); // Primary
  static const darkPrimaryDark = Color(0xFF4F46E5); // Primary Dark (pressed)

  static const darkSuccess = Color(0xFF10B981);
  static const darkWarning = Color(0xFFFBBF24);
  static const darkError   = Color(0xFFF87171);
  static const darkInfo    = Color(0xFF60A5FA);

  static const darkTextPrimary   = Color(0xFFF8FAFC); // Text
  static const darkTextSecondary = Color(0xFFCBD5E1); // Subtext
  static const darkMuted         = Color(0xFF94A3B8); // Muted

  // ── Theme-aware Getters ───────────────────────────────────────────────────
  static Color getSuccess(bool isDark) => isDark ? darkSuccess : success;
  static Color getError(bool isDark)   => isDark ? darkError   : error;
  static Color getWarning(bool isDark) => isDark ? darkWarning : warning;
  static Color getInfo(bool isDark)    => isDark ? darkInfo    : info;

  // ── Status Color Helpers ──────────────────────────────────────────────────
  /// Returns the foreground color for a given attendance status string.
  static Color statusColor(String status, {bool isDark = false}) {
    final s = status.toLowerCase();
    return switch (s) {
      'present'   => isDark ? darkSuccess : success,
      'absent'    => isDark ? darkError   : error,
      'leave'     => isDark ? darkWarning : warning,
      'halfday'   => orange,
      'holiday'   => isDark ? darkInfo : info,
      'weekoff'   => gray,
      'wfh'       => isDark ? darkInfo : info,
      'late'      => isDark ? darkWarning : warning,
      'compoff'   => purple,
      'onduty'    => purple,
      _           => gray,
    };
  }

  /// Returns the subtle (background) color for a given attendance status string.
  static Color statusSubtleColor(String status, {bool isDark = false}) {
    final base = statusColor(status, isDark: isDark);
    return isDark ? base.withAlpha(30) : base.withAlpha(25);
  }

  /// Returns the foreground color for a given approval status string.
  static Color approvalColor(String status, {bool isDark = false}) {
    final s = status.toLowerCase();
    return switch (s) {
      'approved'  => isDark ? darkSuccess : success,
      'rejected'  => isDark ? darkError   : error,
      'pending'   => isDark ? darkWarning : warning,
      'cancelled' => gray,
      'expired'   => gray,
      _           => gray,
    };
  }

  static Color approvalSubtleColor(String status, {bool isDark = false}) {
    final base = approvalColor(status, isDark: isDark);
    if (isDark) return base.withAlpha(30);
    
    return switch (status.toLowerCase()) {
      'approved'  => successSubtle,
      'rejected'  => errorSubtle,
      'pending'   => warningSubtle,
      'cancelled' => graySubtle,
      'expired'   => graySubtle,
      _           => graySubtle,
    };
  }
}

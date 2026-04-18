import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Apple-inspired minimal light/transparent palette.
class FloraPalette {
  const FloraPalette._();

  // Backgrounds
  static const background = Color(
    0xFFF5F5F7,
  ); // Apple standard light background
  static const sidebarBg = Color(0xFFEDEDEF);
  static const panelBg = Color(0xFFFFFFFF);
  static const inputBg = Color(0xFFE3E3E8);
  static const hoveredBg = Color(0xFFE5E5EA);
  static const selectedBg = Color(0xFF007AFF); // Apple Blue

  // Glassy variants (light/frosted)
  static const glassBackground = Color(0x73FFFFFF); // Milky frosted
  static const glassSidebar = Color(0xB3FFFFFF); // More opaque
  static const glassPanel = Color(0x66FFFFFF);
  static const glassBorder = Color(
    0x33000000,
  ); // Subtle dark border for frosted look

  // Borders / dividers
  static const border = Color(0x26000000);

  // Accent
  static const accent = Color(0xFF007AFF);
  static const accentLight = Color(0xFF5AC8FA);

  // Status
  static const success = Color(0xFF34C759);
  static const warning = Color(0xFFFF9500);
  static const error = Color(0xFFFF3B30);

  // Text
  static const textPrimary = Color(0xFF1D1D1F); // Apple dark text
  static const textSecondary = Color(0xFF86868B);
  static const textDimmed = Color(0xFF98989D);
  static const textCode = Color(0xFF24292E);
}

class FloraTheme {
  const FloraTheme._();

  static ThemeData theme() {
    const cs = ColorScheme(
      brightness: Brightness.light,
      primary: FloraPalette.accent,
      onPrimary: Colors.white,
      secondary: FloraPalette.accent,
      onSecondary: Colors.white,
      error: FloraPalette.error,
      onError: Colors.white,
      surface: FloraPalette.sidebarBg,
      onSurface: FloraPalette.textPrimary,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: Colors.transparent,
      dividerColor: FloraPalette.border,
      dividerTheme: const DividerThemeData(
        color: FloraPalette.border,
        thickness: 1,
        space: 1,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(const Color(0x40000000)),
        radius: const Radius.circular(8),
        thickness: WidgetStateProperty.all(6),
      ),
      textTheme: const TextTheme(
        bodyLarge: TextStyle(
          color: FloraPalette.textPrimary,
          fontSize: 13,
          height: 1.5,
        ),
        bodyMedium: TextStyle(
          color: FloraPalette.textPrimary,
          fontSize: 13,
          height: 1.5,
        ),
        bodySmall: TextStyle(
          color: FloraPalette.textSecondary,
          fontSize: 11,
          height: 1.4,
        ),
        labelMedium: TextStyle(
          color: FloraPalette.textSecondary,
          fontSize: 11,
          letterSpacing: 0.3,
          fontWeight: FontWeight.w600,
        ),
        labelSmall: TextStyle(
          color: FloraPalette.textDimmed,
          fontSize: 10,
          letterSpacing: 0.2,
        ),
        titleSmall: TextStyle(
          color: FloraPalette.textPrimary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
      iconTheme: const IconThemeData(
        color: FloraPalette.textSecondary,
        size: 16,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: FloraPalette.inputBg,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        hintStyle: const TextStyle(
          color: FloraPalette.textDimmed,
          fontSize: 13,
        ),
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          borderSide: BorderSide.none,
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          borderSide: BorderSide.none,
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          borderSide: BorderSide(color: FloraPalette.accent, width: 2),
        ),
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: FloraPalette.accent,
        selectionColor: Color(0x33007AFF),
        selectionHandleColor: FloraPalette.accent,
      ),
    );
  }

  /// JetBrains Mono for code / terminal output.
  static TextStyle mono({
    double size = 12,
    Color color = FloraPalette.textCode,
  }) => GoogleFonts.jetBrainsMono(fontSize: size, color: color, height: 1.6);
}

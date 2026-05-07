import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Dark glass palette used across the Flora shell.
class FloraPalette {
  const FloraPalette._();

  // Backgrounds
  static const background = Color(0xFF0D1218);
  static const sidebarBg = Color(0xFF10161D);
  static const panelBg = Color(0xFF141B23);
  static const inputBg = Color(0xFF1A212B);
  static const hoveredBg = Color(0xFF212A36);
  static const selectedBg = Color(0xFF202B38);

  // Glassy variants
  static const glassBackground = Color(0x7310141A);
  static const glassSidebar = Color(0xCC0E1318);
  static const glassPanel = Color(0xC9141A22);
  static const glassBorder = Color(0x1FFFFFFF);

  // Borders / dividers
  static const border = Color(0x24FFFFFF);

  // Accent
  static const accent = Color(0xFF4FB26B);
  static const accentLight = Color(0xFF85D79A);

  // Status
  static const success = Color(0xFF4FB26B);
  static const warning = Color(0xFFF0B35F);
  static const error = Color(0xFFE06E6E);

  // Text
  static const textPrimary = Color(0xFFE7EDF3);
  static const textSecondary = Color(0xFF9AA6B2);
  static const textDimmed = Color(0xFF6B7785);
  static const textCode = Color(0xFFD7DEE7);
}

class FloraTheme {
  const FloraTheme._();

  static ThemeData theme() {
    const cs = ColorScheme(
      brightness: Brightness.dark,
      primary: FloraPalette.accent,
      onPrimary: Colors.white,
      secondary: FloraPalette.accent,
      onSecondary: Colors.white,
      error: FloraPalette.error,
      onError: Colors.white,
      surface: FloraPalette.panelBg,
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
        thumbColor: WidgetStateProperty.all(const Color(0x40FFFFFF)),
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
          borderSide: BorderSide(color: FloraPalette.accent, width: 1.4),
        ),
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: FloraPalette.accent,
        selectionColor: Color(0x334FB26B),
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

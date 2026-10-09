import 'package:flutter/material.dart';

abstract final class AppTheme {
  static ThemeData get light => ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF0B5D4B),
      brightness: Brightness.light,
    ),
    useMaterial3: true,
  );
}

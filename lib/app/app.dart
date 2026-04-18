import 'package:flutter/material.dart';

import '../features/shell/presentation/flora_shell.dart';
import 'theme/flora_theme.dart';

class FloraApp extends StatelessWidget {
  const FloraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flora',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: FloraTheme.theme(),
      home: const FloraShell(),
    );
  }
}

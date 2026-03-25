import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markify/core/theme/app_theme.dart';
import 'package:markify/features/editor/presentation/screens/editor_view.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const ProviderScope(
      child: WatermarkApp(),
    ),
  );
}

class WatermarkApp extends StatelessWidget {
  const WatermarkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Markify',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark, // Default to dark mode for a premium feel
      home: const HomeScreen(),
    );
  }
}

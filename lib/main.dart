import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:money_mate/app/app_dependencies.dart';
import 'package:money_mate/app/money_mate_app.dart';
import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/theme/system_ui.dart';
import 'package:money_mate/firebase_options.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Draw behind transparent status and navigation bars (edge-to-edge).
  await SystemUi.enableEdgeToEdge(
    binding.platformDispatcher.platformBrightness,
  );

  // sqflite uses platform channels on Android/iOS/macOS; desktop builds use
  // the bundled FFI implementation so the app also runs on Windows/Linux.
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  try {
    final dependencies = await AppDependencies.create();
    runApp(MoneyMateApp(dependencies: dependencies));
  } catch (error, stack) {
    debugPrint('Start-up failed: $error\n$stack');
    runApp(StartupErrorApp(error: error));
  }
}

/// Shown if the local database cannot be opened.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: Scaffold(
        body: SafeArea(
          // Scrolls when a long error message does not fit (landscape).
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: [
                const Icon(Icons.error_outline_rounded, size: 56),
                const SizedBox(height: 16),
                const Text(
                  'MoneyMate could not start',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  'Your data has not been changed. Please restart the app.\n\n$error',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

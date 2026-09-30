import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/auth/staff_access_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const CashierApp());
}

const forest = Color(0xFF183E35);
const paper = Color(0xFFF5F4EF);
const ink = Color(0xFF263831);
const gold = Color(0xFFC7AA70);

class CashierApp extends StatefulWidget {
  const CashierApp({super.key});

  @override
  State<CashierApp> createState() => _CashierAppState();
}

class _CashierAppState extends State<CashierApp> with WidgetsBindingObserver {
  Timer? immersiveRestore;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void restoreFullscreen() {
    immersiveRestore?.cancel();
    // Android temporarily prevents hiding navigation after the keyboard closes.
    immersiveRestore = Timer(const Duration(milliseconds: 1300), () {
      if (!mounted) return;
      final binding = WidgetsBinding.instance;
      if (binding.lifecycleState != null &&
          binding.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      if (binding.platformDispatcher.views.any(
        (view) => view.viewInsets.bottom > 0,
      )) {
        return;
      }
      unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
      );
    });
  }

  @override
  void didChangeMetrics() => restoreFullscreen();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      restoreFullscreen();
    } else {
      immersiveRestore?.cancel();
    }
  }

  @override
  void dispose() {
    immersiveRestore?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'KINGCLUB POS',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: paper,
        colorScheme: ColorScheme.fromSeed(
          seedColor: forest,
          primary: forest,
          surface: Colors.white,
        ),
        textTheme: ThemeData.light().textTheme.apply(
          bodyColor: ink,
          displayColor: ink,
        ),
        dividerColor: const Color(0xFFE5E8E1),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF0F2ED),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(48, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(48, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
      home: const StaffAccessPage(),
    );
  }
}

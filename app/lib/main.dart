import 'package:flutter/material.dart';

import 'app_state.dart';
import 'record/recorder.dart';
import 'screens/home.dart';
import 'screens/welcome_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppState.instance.init();
  await Recorder.instance.recover(); // a recording cut off by a crash or flat battery comes back paused
  runApp(const WakeBackApp());
}

class WakeBackApp extends StatelessWidget {
  const WakeBackApp({super.key});

  @override
  Widget build(BuildContext context) {
    // the viewer's own colours: navy panel, signal yellow
    const navy = Color(0xFF13293A), yellow = Color(0xFFFFC72C);
    final scheme = ColorScheme.fromSeed(seedColor: yellow, brightness: Brightness.dark, primary: yellow, surface: const Color(0xFF17324A));
    return MaterialApp(
      title: 'WakeBack',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: navy,
        appBarTheme: const AppBarTheme(backgroundColor: navy, surfaceTintColor: Colors.transparent),
        navigationBarTheme: const NavigationBarThemeData(backgroundColor: Color(0xFF0F2230)),
        cardTheme: CardThemeData(color: const Color(0xFF1A3850), elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      ),
      theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: yellow)),
      routes: {'/home': (_) => const HomeScreen()},
      home: app.welcomed ? const HomeScreen() : const WelcomeScreen(),
    );
  }
}

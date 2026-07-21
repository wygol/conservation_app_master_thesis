import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'screens/login_screen.dart';
import 'screens/notes_screen.dart';
import 'theme.dart';
import 'util.dart';

Future<void> main() async {
  // Boot Flutter's engine bindings before any async work prior to runApp().
  WidgetsFlutterBinding.ensureInitialized();

  // Build the client once; connection itself is lazy (first query).
  // Local dev: phone reaches the laptop's Supabase through the adb reverse
  // tunnel, so 127.0.0.1 is correct on-device (see docs/decisions/001).
  await Supabase.initialize(
    url: 'http://127.0.0.1:54321',
    publishableKey: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = createTextTheme(context, "Roboto", "Roboto");
    final MaterialTheme theme = MaterialTheme(textTheme);

    return MaterialApp(
      title: 'Conservation App',
      theme: theme.light(), // used in light mode
      darkTheme: theme.dark(), // used in dark mode
      themeMode: ThemeMode.system, // follow the phone's light/dark setting
      home: const AuthGate(),
    );
  }
}

/// Decides which screen to show based on the auth session.
/// Listens to onAuthStateChange, so it rebuilds on every sign-in/sign-out.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final supabase = Supabase.instance.client;
    return StreamBuilder<AuthState>(
      stream: supabase.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = supabase.auth.currentSession;
        if (session == null) {
          return const LoginScreen();
        }
        return const NotesScreen(title: 'Notes');
      },
    );
  }
}

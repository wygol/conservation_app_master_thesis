import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'screens/set_password_screen.dart';
import 'services/org_context.dart';
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

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  // One instance for the whole app: which park we are recording under is
  // global state by nature, and passing it down explicitly keeps it visible
  // rather than hiding it in a service locator.
  late final OrgContext _orgContext;

  @override
  void initState() {
    super.initState();
    _orgContext = OrgContext(Supabase.instance.client);
  }

  @override
  void dispose() {
    _orgContext.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = createTextTheme(context, "Roboto", "Roboto");
    final MaterialTheme theme = MaterialTheme(textTheme);

    return MaterialApp(
      title: 'Conservation App',
      theme: theme.light(), // used in light mode
      darkTheme: theme.dark(), // used in dark mode
      themeMode: ThemeMode.system, // follow the phone's light/dark setting
      home: AuthGate(orgContext: _orgContext),
    );
  }
}

/// Decides which screen to show, in three steps:
///
///   1. no session            -> LoginScreen
///   2. session, no password  -> SetPasswordScreen   (arrived via an invitation)
///   3. session, password set -> bootstrap the park context, then HomeShell
///
/// Step 2 exists because there is no self-service sign-up (ADR 004). An admin
/// adds a colleague by e-mail, GoTrue mails a one-time link, and following it
/// produces a session for someone who has never chosen a password. GoTrue does
/// not expose "does this user have a password", so the app records the fact in
/// the user's own metadata when they set one (ADR 006).
class AuthGate extends StatefulWidget {
  const AuthGate({super.key, required this.orgContext});

  final OrgContext orgContext;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final supabase = Supabase.instance.client;
  String? _bootstrappedFor;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: supabase.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = supabase.auth.currentSession;
        final user = supabase.auth.currentUser;

        if (session == null || user == null) {
          _bootstrappedFor = null;
          return const LoginScreen();
        }

        // Only someone who arrived through an invitation is sent here. The
        // `invited` flag is written by GoTrue's admin invite call; the
        // `password_set` flag is written by SetPasswordScreen itself. Testing
        // both means an account that existed before this flow — the seeded
        // dev users, for instance — is never trapped on the screen.
        final invited = user.userMetadata?['invited'] == true;
        final passwordSet = user.userMetadata?['password_set'] == true;
        if (invited && !passwordSet) {
          return const SetPasswordScreen(isFirstTime: true);
        }

        // Claim invitations and load the park list exactly once per session.
        if (_bootstrappedFor != user.id) {
          _bootstrappedFor = user.id;
          // Fire and forget: OrgContext notifies its listeners when done, and
          // the screens below render their own loading state.
          widget.orgContext.bootstrap();
        }

        return HomeShell(orgContext: widget.orgContext);
      },
    );
  }
}

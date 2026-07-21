import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'util.dart';
import 'theme.dart';

Future<void> main() async{
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'http://127.0.0.1:54321',
    publishableKey: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH'
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
      title: 'Flutter Demo',
      theme: theme.light(),         // used in light mode
      darkTheme: theme.dark(),      // used in dark mode
      themeMode: ThemeMode.system,  // follow the phone's light/dark setting
      home: const AuthGate(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final supabase = Supabase.instance.client;
  final _controller = TextEditingController();

  bool _saving = false;
  bool _loading = true;                      // still fetching the list?
  List<Map<String, dynamic>> _notes = [];    // the rows we show
  String? _orgId;                            // NEW: the org this user's notes belong to

  @override
  void initState() {
    super.initState();
    _init();                                 // NEW: org lookup first, then notes
  }

  // NEW: find out which org I belong to, then load that org's notes.
  Future<void> _init() async {
    try {
      // Deliberately NO .eq('user_id', ...) filter here: RLS injects it
      // server-side. The database is physically unable to return any
      // membership row that isn't mine — that's the sovereignty mechanism.
      final rows = await supabase.from('memberships').select('org_id').limit(1);
      if (rows.isNotEmpty) {
        _orgId = rows.first['org_id'] as String;
      }
    } catch (_) {
      // If this fails (no tunnel / offline), _loadNotes below surfaces the error.
    }
    await _loadNotes();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // NEW: read all notes from the DB into _notes.
  Future<void> _loadNotes() async {
    try {
      final data = await supabase
          .from('notes')
          .select()                                  // SELECT *
          .order('created_at', ascending: false);    // newest first
      if (!mounted) return;
      setState(() {
        _notes = List<Map<String, dynamic>>.from(data);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load notes: $e')),
      );
    }
  }

  Future<void> _saveNote() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    // NEW: without a membership there is no org to write into — RLS would
    // reject the insert anyway; this just gives a human-readable reason.
    final orgId = _orgId;
    if (orgId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No organization membership — cannot save.')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      // NEW: every note is written into MY org. The insert policy
      // (WITH CHECK) verifies server-side that I really am a member.
      await supabase.from('notes').insert({'text': text, 'org_id': orgId});
      _controller.clear();
      await _loadNotes();                    // NEW: re-read so the list shows the new row
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved!')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
        actions: [
          IconButton(
            onPressed: () => supabase.auth.signOut(),
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _controller,
              decoration: const InputDecoration(
                labelText: 'New note',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _saving ? null : _saveNote,
              child: Text(_saving ? 'Saving…' : 'Save'),
            ),
            const SizedBox(height: 12),
            // NEW: the list fills the rest of the screen.
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _notes.isEmpty
                      ? const Center(child: Text('No notes yet'))
                      : ListView.builder(
                          itemCount: _notes.length,
                          itemBuilder: (context, i) {
                            final note = _notes[i];
                            return ListTile(
                              title: Text(note['text'] as String),
                              subtitle: Text(note['created_at'] as String),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

// LOGIN SCREEN CODE IS HERE
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final supabase = Supabase.instance.client;
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() => _busy = true);
    try {
      await supabase.auth.signInWithPassword(
        email: _email.text.trim(),
        password: _password.text,
      );
      // No navigation needed — the AuthGate reacts to the auth change.
    } on AuthException catch (e) {
      _showError(e.message);
    } catch (e) {
      _showError(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signUp() async {
    setState(() => _busy = true);
    try {
      await supabase.auth.signUp(
        email: _email.text.trim(),
        password: _password.text,
      );
    } on AuthException catch (e) {
      _showError(e.message);
    } catch (e) {
      _showError(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Email',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: _obscure,
              decoration: InputDecoration(            // note: no longer `const`
                labelText: 'Password',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                  tooltip: _obscure ? 'Show password' : 'Hide password',
                ),
              ),
            ),
            
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _signIn,
              child: Text(_busy ? 'Please wait…' : 'Sign in'),
            ),
            TextButton(
              onPressed: _busy ? null : _signUp,
              child: const Text('Create account'),
            ),
          ],
        ),
      ),
    );
  }
}


// AUTH GATE CODE HERE
// auth gate becomes the new home and checks if user is already loggerd in 
// (session stored on device) or if login site has to be launched to log in

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final supabase = Supabase.instance.client;
    // onAuthStateChange fires on sign-in / sign-out and rebuilds this.
    return StreamBuilder<AuthState>(
      stream: supabase.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = supabase.auth.currentSession;
        if (session == null) {
          return const LoginScreen();
        }
        return const MyHomePage(title: 'Notes');
      },
    );
  }
}
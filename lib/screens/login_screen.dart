import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'model_lab_screen.dart';

/// Sign-in only — there is deliberately NO self-service sign-up.
/// Accounts are provisioned by the operator / org admins (ADR 004:
/// sales-led onboarding). GoTrue signup is also disabled server-side
/// (supabase/config.toml → enable_signup = false), so this UI merely
/// reflects a rule the backend enforces anyway.
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

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Explains how accounts are created instead of offering sign-up.
  void _showAccessInfo() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Need access?'),
        content: const Text(
          'Accounts are managed by your organization.\n\n'
          'Please ask your organization\'s administrator to create an '
          'account for you — self-service sign-up is not available.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
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
              decoration: InputDecoration(
                labelText: 'Password',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                      _obscure ? Icons.visibility : Icons.visibility_off),
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
              onPressed: _busy ? null : _showAccessInfo,
              child: const Text('Need access? Ask your admin'),
            ),
            // The bundled model needs no account and no network (sovereignty
            // tier 3), so it is reachable before signing in.
            TextButton.icon(
              onPressed: _busy
                  ? null
                  : () => Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => const ModelLabScreen(),
                      )),
              icon: const Icon(Icons.center_focus_weak_outlined),
              label: const Text('On-device model (works offline)'),
            ),
          ],
        ),
      ),
    );
  }
}

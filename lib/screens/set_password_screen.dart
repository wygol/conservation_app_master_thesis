import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Shown once, to a person who arrived through an invitation link.
///
/// The invitation flow (ADR 006): an admin adds a colleague's e-mail; GoTrue
/// mails a one-time link; following it signs them in without a password ever
/// having been chosen. This screen is where they choose one. It is also
/// reachable from Settings for an ordinary password change.
///
/// "Has this person set a password yet?" is answered by a flag in the user's
/// own metadata rather than by anything server-side, because GoTrue does not
/// expose whether a password exists.
class SetPasswordScreen extends StatefulWidget {
  const SetPasswordScreen({super.key, this.isFirstTime = true});

  final bool isFirstTime;

  @override
  State<SetPasswordScreen> createState() => _SetPasswordScreenState();
}

class _SetPasswordScreenState extends State<SetPasswordScreen> {
  final supabase = Supabase.instance.client;
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _validationError;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  String? _validate() {
    final pw = _password.text;
    if (pw.length < 8) return 'Use at least 8 characters.';
    if (pw != _confirm.text) return 'The two passwords do not match.';
    return null;
  }

  Future<void> _save() async {
    final problem = _validate();
    if (problem != null) {
      setState(() => _validationError = problem);
      return;
    }
    setState(() {
      _busy = true;
      _validationError = null;
    });
    try {
      await supabase.auth.updateUser(
        UserAttributes(
          password: _password.text,
          // The flag AuthGate reads to decide whether to show this screen.
          data: {'password_set': true},
        ),
      );
      if (!mounted) return;
      if (widget.isFirstTime) {
        // AuthGate rebuilds on the user update and moves on by itself.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Password set. Welcome.')),
        );
      } else {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Password changed.')),
        );
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _validationError = e.message);
    } catch (e) {
      if (mounted) setState(() => _validationError = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = supabase.auth.currentUser?.email ?? '';
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isFirstTime ? 'Choose a password' : 'Change password'),
        automaticallyImplyLeading: !widget.isFirstTime,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.isFirstTime) ...[
              Text(
                'You were invited as $email.',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 4),
              Text(
                'Choose a password to finish setting up your account. '
                'Nobody else — including your administrator — can see it.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
            ],
            TextField(
              controller: _password,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.newPassword],
              decoration: InputDecoration(
                labelText: 'New password',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                  tooltip: _obscure ? 'Show password' : 'Hide password',
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirm,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.newPassword],
              decoration: const InputDecoration(
                labelText: 'Repeat password',
                border: OutlineInputBorder(),
              ),
            ),
            if (_validationError != null) ...[
              const SizedBox(height: 12),
              Text(
                _validationError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_busy ? 'Please wait…' : 'Save password'),
            ),
          ],
        ),
      ),
    );
  }
}

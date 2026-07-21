import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The org-scoped notes screen (placeholder domain until `observations`).
/// Pattern: resolve WHO I am / WHERE I belong first, then load data;
/// after every successful write, re-read from the DB (DB = source of truth).
class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key, required this.title});

  final String title;

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  final supabase = Supabase.instance.client;
  final _controller = TextEditingController();

  bool _saving = false;
  bool _loading = true; // still fetching the list?
  List<Map<String, dynamic>> _notes = []; // the rows we show
  String? _orgId; // the org this user's notes belong to

  @override
  void initState() {
    super.initState();
    _init(); // org lookup first, then notes
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // Find out which org I belong to, then load that org's notes.
  Future<void> _init() async {
    try {
      // Deliberately NO .eq('user_id', ...) filter here: RLS injects it
      // server-side. The database is physically unable to return any
      // membership row that isn't mine — that's the sovereignty mechanism.
      final rows =
          await supabase.from('memberships').select('org_id').limit(1);
      if (rows.isNotEmpty) {
        _orgId = rows.first['org_id'] as String;
      }
    } catch (_) {
      // If this fails (no tunnel / offline), _loadNotes below surfaces it.
    }
    await _loadNotes();
  }

  // Read all notes visible to me (RLS: my org only) into _notes.
  Future<void> _loadNotes() async {
    try {
      final data = await supabase
          .from('notes')
          .select() // SELECT *
          .order('created_at', ascending: false); // newest first
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

    // Without a membership there is no org to write into — RLS would
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
      // Every note is written into MY org. The insert policy (WITH CHECK)
      // verifies server-side that I really am a member.
      await supabase.from('notes').insert({'text': text, 'org_id': orgId});
      _controller.clear();
      await _loadNotes(); // re-read so the list shows the new row
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

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/models.dart';
import '../services/org_context.dart';
import 'members_screen.dart';
import 'set_password_screen.dart';

/// Settings — and, more importantly, the one place where a person who works
/// for more than one park changes which park they are recording under
/// (ADR 005). It is here rather than on the capture screen on purpose:
/// switching park is a deliberate act, not something to do by accident with a
/// thumb while holding a plant.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.orgContext});

  final OrgContext orgContext;

  @override
  Widget build(BuildContext context) {
    final supabase = Supabase.instance.client;
    final email = supabase.auth.currentUser?.email ?? '—';

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: orgContext,
        builder: (context, _) {
          final parks = orgContext.parks;
          final active = orgContext.activePark;

          return ListView(
            children: [
              const _SectionHeader('Park'),
              if (parks.isEmpty)
                const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('You do not belong to a park yet'),
                  subtitle: Text(
                    'Ask an administrator to invite you. Until then there is '
                    'nowhere for a record to go.',
                  ),
                )
              else ...[
                if (parks.length == 1)
                  ListTile(
                    leading: const Icon(Icons.park_outlined),
                    title: Text(parks.first.name),
                    subtitle: Text('You are a ${parks.first.role} here'),
                  )
                else
                  ...parks.map(
                    (p) => RadioListTile<String>(
                      value: p.orgId,
                      groupValue: active?.orgId,
                      title: Text(p.name),
                      subtitle: Text('You are a ${p.role} here'),
                      secondary: p.isAdmin
                          ? const Icon(Icons.shield_outlined)
                          : const Icon(Icons.park_outlined),
                      onChanged: (value) async {
                        if (value == null) return;
                        try {
                          await orgContext.switchTo(value);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Now recording for ${p.name}')),
                          );
                        } catch (e) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Could not switch: $e')),
                          );
                        }
                      },
                    ),
                  ),
                if (parks.length > 1)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: Text(
                      'New records are written to the selected park. Records '
                      'already made stay where they were made.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
              ],

              if (active != null) ...[
                const Divider(),
                const _SectionHeader('People'),
                ListTile(
                  leading: const Icon(Icons.group_outlined),
                  title: Text(active.isAdmin
                      ? 'Manage people in ${active.name}'
                      : 'People in ${active.name}'),
                  subtitle: Text(active.isAdmin
                      ? 'Invite, change roles, remove — records are never deleted'
                      : 'See who else records here'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => MembersScreen(park: active),
                    ),
                  ),
                ),
                if (active.isAdmin)
                  ListTile(
                    leading: const Icon(Icons.person_add_alt),
                    title: const Text('Invite a colleague'),
                    subtitle: Text('Add someone to ${active.name} by e-mail'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => InviteScreen(park: active),
                      ),
                    ),
                  ),
              ],

              const Divider(),
              const _SectionHeader('Account'),
              ListTile(
                leading: const Icon(Icons.mail_outline),
                title: const Text('Signed in as'),
                subtitle: Text(email),
              ),
              ListTile(
                leading: const Icon(Icons.password),
                title: const Text('Change password'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SetPasswordScreen(isFirstTime: false),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Sign out'),
                onTap: () async {
                  orgContext.clear();
                  await supabase.auth.signOut();
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(
          text.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                letterSpacing: 1.2,
              ),
        ),
      );
}

/// Admin-only. Creates an `invitations` row for the active park.
///
/// It does not send the e-mail: that needs the service-role key, which never
/// lives in the app (CLAUDE.md section 7). A server-side step picks the
/// pending row up and calls GoTrue's admin invite endpoint. Until that step
/// exists, `tools/invite_user.ps1` does it by hand — which is honest for a
/// thesis artefact and is exactly the sales-led onboarding of ADR 004.
class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key, required this.park});

  final Park park;

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  final supabase = Supabase.instance.client;
  final _email = TextEditingController();
  String _role = 'member';
  bool _busy = false;
  bool _loading = true;
  List<Invitation> _invitations = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await supabase
          .from('invitations')
          .select()
          .eq('org_id', widget.park.orgId)
          .order('created_at', ascending: false);
      if (!mounted) return;
      setState(() {
        _invitations = rows.map((r) => Invitation.fromMap(r)).toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not load invitations: $e')));
    }
  }

  Future<void> _invite() async {
    final email = _email.text.trim().toLowerCase();
    if (!email.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That does not look like an e-mail address.')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await supabase.from('invitations').insert({
        'org_id': widget.park.orgId,
        'email': email, // the table requires lower case
        'role': _role,
        'invited_by': supabase.auth.currentUser!.id,
      });
      _email.clear();
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$email invited to ${widget.park.name}.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not invite: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke(Invitation inv) async {
    try {
      await supabase
          .from('invitations')
          .update({'status': 'revoked'}).eq('id', inv.id);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not revoke: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Invite to ${widget.park.name}')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'E-mail address',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'member', label: Text('Member')),
                    ButtonSegment(value: 'admin', label: Text('Admin')),
                  ],
                  selected: {_role},
                  onSelectionChanged: (s) => setState(() => _role = s.first),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _busy ? null : _invite,
                  icon: const Icon(Icons.send),
                  label: Text(_busy ? 'Please wait…' : 'Send invitation'),
                ),
                const SizedBox(height: 8),
                Text(
                  'They receive a link, choose their own password, and land in '
                  'this park. The invitation expires after 14 days.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _invitations.isEmpty
                    ? const Center(child: Text('No invitations yet.'))
                    : ListView.builder(
                        itemCount: _invitations.length,
                        itemBuilder: (context, i) {
                          final inv = _invitations[i];
                          return ListTile(
                            leading: Icon(
                              inv.status == 'accepted'
                                  ? Icons.check_circle_outline
                                  : inv.isLive
                                      ? Icons.hourglass_empty
                                      : Icons.cancel_outlined,
                            ),
                            title: Text(inv.email),
                            subtitle: Text('${inv.role} · ${inv.status}'),
                            trailing: inv.isLive
                                ? TextButton(
                                    onPressed: () => _revoke(inv),
                                    child: const Text('Revoke'),
                                  )
                                : null,
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

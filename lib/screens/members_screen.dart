import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/models.dart';
import '../models/models_extra.dart';
import 'settings_screen.dart' show InviteScreen;

/// Who is in this park, and — for an admin — getting them in and out.
///
/// Removing someone deletes their **membership**, never their records. The
/// count next to each person is how many observations they recorded here, and
/// it is shown precisely so that removing an active recorder is a considered
/// act rather than a reflex.
class MembersScreen extends StatefulWidget {
  const MembersScreen({super.key, required this.park});

  final Park park;

  @override
  State<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends State<MembersScreen> {
  final supabase = Supabase.instance.client;
  bool _loading = true;
  String? _error;
  List<ParkMember> _members = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await supabase
          .rpc('park_members', params: {'p_org_id': widget.park.orgId});
      if (!mounted) return;
      setState(() {
        _members = (rows as List)
            .map((r) => ParkMember.fromMap(r as Map<String, dynamic>))
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _remove(ParkMember m) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${m.email}?'),
        content: Text(
          m.observationCount == 0
              ? 'They will lose access to ${widget.park.name}. '
                  'They have recorded nothing here.'
              : 'They will lose access to ${widget.park.name}.\n\n'
                  'Their ${m.observationCount} record'
                  '${m.observationCount == 1 ? '' : 's'} '
                  'stay in the park and keep their name as the recorder — '
                  'nothing is deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await supabase.rpc('remove_member', params: {
        'p_user_id': m.userId,
        'p_org_id': widget.park.orgId,
      });
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${m.email} removed. Their records stay.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not remove: $e')));
    }
  }

  Future<void> _setRole(ParkMember m, String role) async {
    try {
      await supabase.rpc('set_member_role', params: {
        'p_user_id': m.userId,
        'p_org_id': widget.park.orgId,
        'p_role': role,
      });
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not change role: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = widget.park.isAdmin;
    return Scaffold(
      appBar: AppBar(title: Text('People in ${widget.park.name}')),
      floatingActionButton: !isAdmin
          ? null
          : FloatingActionButton.extended(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => InviteScreen(park: widget.park),
                  ),
                );
                await _load();
              },
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Invite'),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Could not load: $_error'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    itemCount: _members.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final m = _members[i];
                      return ListTile(
                        leading: Icon(m.isAdmin
                            ? Icons.shield_outlined
                            : Icons.person_outline),
                        title: Text(m.email + (m.isSelf ? '  (you)' : '')),
                        subtitle: Text(
                          '${m.role} · ${m.observationCount} record'
                          '${m.observationCount == 1 ? '' : 's'} here',
                        ),
                        trailing: !isAdmin || m.isSelf
                            ? null
                            : PopupMenuButton<String>(
                                onSelected: (v) {
                                  if (v == 'remove') {
                                    _remove(m);
                                  } else {
                                    _setRole(m, v);
                                  }
                                },
                                itemBuilder: (context) => [
                                  if (!m.isAdmin)
                                    const PopupMenuItem(
                                      value: 'admin',
                                      child: Text('Make admin'),
                                    ),
                                  if (m.isAdmin)
                                    const PopupMenuItem(
                                      value: 'member',
                                      child: Text('Make member'),
                                    ),
                                  const PopupMenuItem(
                                    value: 'remove',
                                    child: Text('Remove from park'),
                                  ),
                                ],
                              ),
                      );
                    },
                  ),
                ),
    );
  }
}

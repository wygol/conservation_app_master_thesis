import 'package:flutter/material.dart';

import '../services/org_context.dart';
import 'notes_screen.dart';
import 'observations_screen.dart';
import 'settings_screen.dart';

/// The signed-in shell. Three destinations for now; the map and the capture
/// flow join it next.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.orgContext});

  final OrgContext orgContext;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      ObservationsScreen(orgContext: widget.orgContext),
      const NotesScreen(title: 'Notes'), // the original placeholder domain
      SettingsScreen(orgContext: widget.orgContext),
    ];

    return Scaffold(
      body: pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.eco_outlined),
            selectedIcon: Icon(Icons.eco),
            label: 'Records',
          ),
          NavigationDestination(
            icon: Icon(Icons.sticky_note_2_outlined),
            selectedIcon: Icon(Icons.sticky_note_2),
            label: 'Notes',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

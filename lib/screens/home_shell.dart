import 'package:flutter/material.dart';

import '../services/org_context.dart';
import 'model_lab_screen.dart';
import 'observations_screen.dart';
import 'settings_screen.dart';

/// The signed-in shell. "Identify" is the on-device model — a model lab for
/// the measurement round today, the capture flow's home later. The original
/// Notes placeholder (screens/notes_screen.dart) left the bar on 2026-10-09;
/// its code stays as the reference pattern of the first vertical slice.
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
      const ModelLabScreen(),
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
            icon: Icon(Icons.center_focus_weak_outlined),
            selectedIcon: Icon(Icons.center_focus_strong),
            label: 'Identify',
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

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Bottom-navigation shell (§6: bottom nav shell / IndexedStack).
///
/// Three destinations, not four: adding is an ACTION (the dashboard FAB),
/// not a place you navigate to. The old 'Add' tab led to a dead placeholder
/// screen for exactly that reason — there was nothing for it to be.
///
/// Wraps a [StatefulNavigationShell]. Because the router uses
/// [StatefulShellRoute.indexedStack], each tab keeps its own navigation
/// state and widget tree when switching — matching IndexedStack behavior.
class NavShell extends StatelessWidget {
  const NavShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const _destinations = <NavigationDestination>[
    NavigationDestination(
      icon: Icon(Icons.home_outlined),
      selectedIcon: Icon(Icons.home),
      label: 'Home',
    ),
    NavigationDestination(
      icon: Icon(Icons.rule_outlined),
      selectedIcon: Icon(Icons.rule),
      label: 'Reconcile',
    ),
    NavigationDestination(
      icon: Icon(Icons.assessment_outlined),
      selectedIcon: Icon(Icons.assessment),
      label: 'Reports',
    ),
  ];

  void _onDestinationSelected(int index) {
    // goBranch preserves the target branch's state; initialLocation only
    // resets it when re-tapping the already-active tab.
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: _onDestinationSelected,
        destinations: _destinations,
      ),
    );
  }
}

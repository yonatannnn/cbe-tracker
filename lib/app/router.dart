import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/add_single/add_single_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/reconcile/reconcile_screen.dart';
import '../features/reports/reports_screen.dart';
import 'nav_shell.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();

/// Application router (§8 Phase 0).
///
/// A [StatefulShellRoute.indexedStack] gives the 4-tab bottom nav an
/// IndexedStack: each branch is kept alive so tab state is preserved when
/// switching.
final GoRouter appRouter = GoRouter(
  navigatorKey: _rootNavigatorKey,
  initialLocation: '/home',
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          NavShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/home',
              builder: (context, state) => const DashboardScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/add',
              builder: (context, state) => const AddScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/reconcile',
              builder: (context, state) => const ReconcileScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/reports',
              builder: (context, state) => const ReportsScreen(),
            ),
          ],
        ),
      ],
    ),
  ],
);

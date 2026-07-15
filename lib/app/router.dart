import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/db/database_provider.dart';
import '../features/add_single/add_single_screen.dart';
import '../features/branch_detail/branch_detail_screen.dart';
import '../features/bulk_add/bulk_add_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/reconcile/reconcile_screen.dart';
import '../features/reports/reports_screen.dart';
import 'nav_shell.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();

/// Application router (§8 Phase 0/3).
///
/// A [StatefulShellRoute.indexedStack] gives the 4-tab bottom nav an
/// IndexedStack, so tab state is preserved when switching. A redirect gates
/// first run: zero branches → onboarding.
final routerProvider = Provider<GoRouter>((ref) {
  // Re-runs the redirect whenever the branch list changes (e.g. the first
  // branch is created, or the last one is removed).
  final refresh = ValueNotifier<int>(0);
  ref.listen(activeBranchesProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/home',
    refreshListenable: refresh,
    redirect: (context, state) {
      final branches = ref.read(activeBranchesProvider).value;
      if (branches == null) return null; // still loading — stay put
      final onboarding = state.matchedLocation == '/onboarding';
      // First run is derived from the branch count, not SharedPreferences.
      if (branches.isEmpty && !onboarding) return '/onboarding';
      // Never auto-leave onboarding — the Done button navigates, so the user
      // can add several branches before continuing.
      return null;
    },
    routes: [
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        path: '/add-single',
        builder: (context, state) => const AddSinglePlaceholderScreen(),
      ),
      GoRoute(
        path: '/add-bulk',
        builder: (context, state) => const BulkAddPlaceholderScreen(),
      ),
      GoRoute(
        path: '/branch/:id',
        builder: (context, state) => BranchDetailPlaceholderScreen(
          branchId: int.parse(state.pathParameters['id']!),
        ),
      ),
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
});

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/db/database_provider.dart';
import '../data/profiles/profile_provider.dart';
import '../features/add_single/add_single_screen.dart';
import '../features/branch_detail/branch_detail_screen.dart';
import '../features/branches/branches_screen.dart';
import '../features/branch_detail/transaction_detail_screen.dart';
import '../features/bulk_add/bulk_add_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/reports/reports_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/welcome/welcome_screen.dart';
import 'nav_shell.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();

/// Application router (§8 Phase 0/3).
///
/// A [StatefulShellRoute.indexedStack] gives the 2-tab bottom nav an
/// IndexedStack, so tab state is preserved when switching. A redirect gates
/// first run in two steps: no signed-in user → welcome (ask her name); a
/// user with zero branches → onboarding.
final routerProvider = Provider<GoRouter>((ref) {
  // Re-runs the redirect whenever the signed-in user or the branch list
  // changes (e.g. the first branch is created, or the user switches).
  final refresh = ValueNotifier<int>(0);
  ref.listen(activeProfileProvider, (_, _) => refresh.value++);
  ref.listen(activeBranchesProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/home',
    refreshListenable: refresh,
    redirect: (context, state) {
      final location = state.matchedLocation;

      // Step 1: who is this? Nothing DB-backed may build before we know,
      // because the answer decides WHICH database opens.
      final profile = ref.read(activeProfileProvider);
      final atWelcome = location == '/welcome';
      if (profile == null) return atWelcome ? null : '/welcome';
      // Welcome stays reachable on purpose (Settings → add another user).
      if (atWelcome) return null;

      // Step 2: her branches. Watched only once a profile exists, so the
      // database is never touched on the welcome screen.
      final branches = ref.read(activeBranchesProvider).value;
      if (branches == null) return null; // still loading — stay put
      final onboarding = location == '/onboarding';
      // First run is derived from the branch count, not SharedPreferences.
      if (branches.isEmpty && !onboarding) return '/onboarding';
      // Never auto-leave onboarding — the Done button navigates, so the user
      // can add several branches before continuing.
      return null;
    },
    routes: [
      GoRoute(
        path: '/welcome',
        builder: (context, state) => const WelcomeScreen(),
      ),
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        path: '/branches',
        builder: (context, state) => const BranchesScreen(),
      ),
      GoRoute(
        path: '/add-single',
        builder: (context, state) => const AddSingleScreen(),
      ),
      GoRoute(
        path: '/add-bulk',
        builder: (context, state) => const BulkAddScreen(),
      ),
      GoRoute(
        path: '/branch/:id',
        builder: (context, state) => BranchDetailScreen(
          branchId: int.parse(state.pathParameters['id']!),
        ),
        routes: [
          // The main flow: inside a branch, drop the day's screenshots.
          GoRoute(
            path: 'add',
            builder: (context, state) => BulkAddScreen(
              initialBranchId: int.parse(state.pathParameters['id']!),
            ),
          ),
        ],
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/transaction/:id',
        builder: (context, state) => TransactionDetailScreen(
          transactionId: int.parse(state.pathParameters['id']!),
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/db/database_provider.dart';
import '../features/reconcile/reconcile_providers.dart';
import '../features/reports/reports_providers.dart';
import '../services/notification_service.dart';
import 'router.dart';
import 'theme.dart';

/// Root application widget.
class CbeTrackerApp extends ConsumerStatefulWidget {
  const CbeTrackerApp({super.key, this.bootstrapReminder = true});

  /// Arms the daily report reminder on launch.
  ///
  /// Off in widget tests, which boot neither the notification plugin nor a
  /// database — an explicit flag rather than swallowing the resulting errors,
  /// which would hide a genuinely broken reminder in production.
  final bool bootstrapReminder;

  @override
  ConsumerState<CbeTrackerApp> createState() => _CbeTrackerAppState();
}

class _CbeTrackerAppState extends ConsumerState<CbeTrackerApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.bootstrapReminder) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _initReminder());
    }
  }

  /// Re-arms the daily reminder on launch.
  ///
  /// Android drops scheduled alarms on reboot and on app update, so scheduling
  /// once at setup time isn't enough — the reminder would quietly stop.
  Future<void> _initReminder() async {
    final notifications = ref.read(notificationServiceProvider);
    await notifications.init(
      onTap: (payload) {
        if (payload == 'reports') _router?.go('/reports');
      },
    );

    final raw = await ref.read(settingsDaoProvider).getReminderTime();
    if (raw == 'off') return; // the user turned it off
    final time = ReminderTime.parse(raw) ?? ReminderTime.defaultTime;
    await notifications.scheduleDaily(time);
  }

  GoRouter? get _router => mounted ? ref.read(routerProvider) : null;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // SMS may have arrived in the background while we were away (§FR-5).
    if (state == AppLifecycleState.resumed) {
      ref.read(reconcileServiceProvider).reconcile();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'CBE Branch Expense Tracker',
      theme: AppTheme.light(),
      routerConfig: ref.watch(routerProvider),
    );
  }
}

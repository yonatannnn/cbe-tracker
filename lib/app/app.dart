import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/reconcile/reconcile_providers.dart';
import 'router.dart';
import 'theme.dart';

/// Root application widget.
class CbeTrackerApp extends ConsumerStatefulWidget {
  const CbeTrackerApp({super.key});

  @override
  ConsumerState<CbeTrackerApp> createState() => _CbeTrackerAppState();
}

class _CbeTrackerAppState extends ConsumerState<CbeTrackerApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

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

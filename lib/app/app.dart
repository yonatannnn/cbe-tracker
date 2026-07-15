import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'theme.dart';

/// Root application widget.
class CbeTrackerApp extends ConsumerWidget {
  const CbeTrackerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'CBE Branch Expense Tracker',
      theme: AppTheme.light(),
      routerConfig: ref.watch(routerProvider),
    );
  }
}

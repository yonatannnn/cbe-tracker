import 'package:flutter/material.dart';

import 'router.dart';
import 'theme.dart';

/// Root application widget.
class CbeTrackerApp extends StatelessWidget {
  const CbeTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'CBE Branch Expense Tracker',
      theme: AppTheme.light(),
      routerConfig: appRouter,
    );
  }
}

// Phase 0 smoke test: the app boots into a 4-tab shell and tabs switch,
// preserving each branch via the router's IndexedStack.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cbe_tracker/app/app.dart';

void main() {
  testWidgets('boots with 4 tabs and Home shown', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: CbeTrackerApp()));
    await tester.pumpAndSettle();

    // Bottom navigation has all 4 destinations.
    expect(find.text('Home'), findsWidgets);
    expect(find.text('Add'), findsOneWidget);
    expect(find.text('Reconcile'), findsOneWidget);
    expect(find.text('Reports'), findsOneWidget);

    // Home tab is the initial location (AppBar + body both read "Home").
    expect(find.widgetWithText(AppBar, 'Home'), findsOneWidget);
  });

  testWidgets('switching to Reports tab shows Reports', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: CbeTrackerApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(NavigationDestination, 'Reports'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Reports'), findsOneWidget);
  });
}

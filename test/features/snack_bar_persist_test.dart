// Characterisation test for the Flutter default that stranded the "Marked
// personal" bar on screen (§9).
//
// Flutter 3.44's SnackBar constructor does `persist = persist ?? action != null`
// (snack_bar.dart), and ScaffoldMessenger's dismissal timer opens with
// `if (snackBar.persist) return;`. So ANY snack bar carrying an action stays up
// forever by default. Ours also has no close icon, which left tapping Undo —
// reversing the choice she had just made — as the only way to get rid of it.
//
// These tests exist because the fix is a single easy-to-delete word. If someone
// drops `persist: false` from an Undo bar, the first test fails and says why.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Shows [snackBar] from a button tap, the way the app does.
  Future<void> show(WidgetTester tester, SnackBar snackBar) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () =>
                  ScaffoldMessenger.of(context).showSnackBar(snackBar),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump(); // schedule
    await tester.pump(const Duration(milliseconds: 750)); // finish entering
  }

  testWidgets('an Undo bar with persist:false disappears on its own', (
    tester,
  ) async {
    await show(
      tester,
      SnackBar(
        content: const Text('Marked personal'),
        persist: false,
        action: SnackBarAction(label: 'Undo', onPressed: () {}),
      ),
    );
    expect(find.text('Marked personal'), findsOneWidget);

    // Default duration is 4s; wait it out plus the exit animation.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(
      find.text('Marked personal'),
      findsNothing,
      reason: 'she never tapped Undo, so the bar must time out by itself',
    );
  });

  testWidgets('without persist:false the same bar never leaves', (
    tester,
  ) async {
    // Pins the framework default that caused the bug. If this ever starts
    // failing, Flutter changed the default and the explicit persist: false in
    // reconcile_screen.dart is no longer load-bearing.
    await show(
      tester,
      SnackBar(
        content: const Text('Marked personal'),
        action: SnackBarAction(label: 'Undo', onPressed: () {}),
      ),
    );
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();

    expect(
      find.text('Marked personal'),
      findsOneWidget,
      reason: 'action => persist defaults true, so it is still stuck on screen',
    );
  });

  testWidgets('a bar with no action still auto-dismisses', (tester) async {
    // The plain confirmations ("Saved to Bole") were never affected — only bars
    // with an action are. Recorded so the fix does not spread where it is not
    // needed.
    await show(tester, const SnackBar(content: Text('Saved to Bole')));
    expect(find.text('Saved to Bole'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(find.text('Saved to Bole'), findsNothing);
  });
}

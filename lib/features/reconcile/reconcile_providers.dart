/// Reconcile providers (§FR-5).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Count of today's unmatched CBE SMS — drives the dashboard warning banner.
///
/// STUBBED to 0 until Phase 6 wires the real SMS shadow ledger; the banner is
/// hidden while the count is 0, so the dashboard renders its final shape now.
final unmatchedSmsCountProvider = StreamProvider<int>(
  (ref) => Stream<int>.value(0),
);

/// Whether a given FT reference has a matching CBE SMS in the shadow ledger.
///
/// STUBBED to null (= "unknown, not checked") until Phase 6 implements SMS
/// reading. The confirm screen hides its verification line while this is null.
final smsVerifiedProvider = Provider.family<bool?, String?>(
  (ref, reference) => null,
);

/// CBE SMS reading — Android only (§FR-4).
///
/// Behind an interface with a no-op iOS implementation, so iOS builds clean and
/// the app stays fully usable via screenshots (§6).
///
/// SMS feeds the shadow ledger ONLY. It never affects balances.
library;

import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:another_telephony/telephony.dart' hide Value;
import 'package:drift/drift.dart' show Value;
import 'package:flutter/widgets.dart';

import '../core/parser/cbe_parser.dart';
import '../data/db/database.dart';
import 'reconcile_service.dart';

/// Sender ids vary ("CBE", "CBE Bank", "CBEBirr"), so match on containment.
bool isCbeSender(String? address) =>
    address != null && address.toLowerCase().contains('cbe');

abstract class SmsService {
  /// False on iOS — the UI shows an explanatory empty state instead.
  bool get isSupported;

  /// Triggers the system permission dialog. Returns whether it was granted.
  Future<bool> requestPermission();

  /// Reads the CBE inbox and stores what parses. Returns how many were stored.
  Future<int> syncInbox();

  /// Starts foreground + background listening for new CBE messages.
  Future<void> startListening();
}

/// iOS (and anything else): everything no-ops, nothing throws.
class NoopSmsService implements SmsService {
  const NoopSmsService();

  @override
  bool get isSupported => false;

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<int> syncInbox() async => 0;

  @override
  Future<void> startListening() async {}
}

/// Parses one CBE SMS body into the shadow ledger.
///
/// Returns true when it was stored. There is deliberately NO Gemini fallback
/// here: an SMS is raw digital text, not OCR, so if the shared parser can't
/// read it the parser is missing a real format — and we want that recorded,
/// not papered over by an LLM. The body goes to the debug log for fixture
/// harvesting (which is exactly how the app-receipt format was found).
Future<bool> ingestCbeSms({
  required AppDatabase db,
  required String address,
  required String body,
  required DateTime receivedAt,
}) async {
  try {
    final parsed = parseCbeText(body);
    await db.smsDao.insertIfNew(
      SmsTransactionsCompanion.insert(
        amountCents: parsed.amountCents,
        smsBody: body,
        receivedAt: receivedAt,
        type: Value(parsed.type),
        reference: Value(parsed.reference),
      ),
    );
    // A parser fix can make a previously-logged body readable; retire the
    // stale debug entry so the log always means "cannot read this today".
    await db.smsDao.clearDebugFor(body);
    return true;
  } on ParseException catch (error) {
    await db.smsDao.logUnreadable(
      address: address,
      body: body,
      receivedAt: receivedAt,
      reason: error.message,
    );
    return false;
  }
}

/// Background isolate entry point for incoming SMS.
///
/// MUST be top-level and vm:entry-point — the plugin looks it up by callback
/// handle. It runs in its own isolate with no access to the app's providers,
/// so it opens (and closes) its own database.
@pragma('vm:entry-point')
Future<void> cbeSmsBackgroundHandler(SmsMessage message) async {
  if (!isCbeSender(message.address)) return;

  WidgetsFlutterBinding.ensureInitialized();
  // Plugins aren't registered automatically in a background isolate.
  DartPluginRegistrant.ensureInitialized();

  final db = AppDatabase();
  try {
    await ingestCbeSms(
      db: db,
      address: message.address ?? '',
      body: message.body ?? '',
      receivedAt: _receivedAt(message),
    );
    await ReconcileService(
      smsDao: db.smsDao,
      transactionDao: db.transactionDao,
    ).reconcile();
  } finally {
    await db.close();
  }
}

DateTime _receivedAt(SmsMessage message) => message.date == null
    ? DateTime.now()
    : DateTime.fromMillisecondsSinceEpoch(message.date!);

class AndroidSmsService implements SmsService {
  AndroidSmsService({required this.db, required this.reconciler});

  final AppDatabase db;
  final ReconcileService reconciler;
  final Telephony _telephony = Telephony.instance;

  @override
  bool get isSupported => true;

  @override
  Future<bool> requestPermission() async =>
      await _telephony.requestSmsPermissions ?? false;

  @override
  Future<int> syncInbox() async {
    final messages = await _telephony.getInboxSms(
      columns: [SmsColumn.ADDRESS, SmsColumn.BODY, SmsColumn.DATE],
      // LIKE is case-insensitive for ASCII, and %CBE% catches "CBE Bank" too.
      filter: SmsFilter.where(SmsColumn.ADDRESS).like('%CBE%'),
    );

    var stored = 0;
    for (final message in messages) {
      // The provider filter is a coarse net; re-check before parsing.
      if (!isCbeSender(message.address)) continue;
      final ok = await ingestCbeSms(
        db: db,
        address: message.address ?? '',
        body: message.body ?? '',
        receivedAt: _receivedAt(message),
      );
      if (ok) stored++;
    }

    await reconciler.reconcile();
    return stored;
  }

  @override
  Future<void> startListening() async {
    _telephony.listenIncomingSms(
      onNewMessage: (message) async {
        if (!isCbeSender(message.address)) return;
        await ingestCbeSms(
          db: db,
          address: message.address ?? '',
          body: message.body ?? '',
          receivedAt: _receivedAt(message),
        );
        await reconciler.reconcile();
      },
      onBackgroundMessage: cbeSmsBackgroundHandler,
    );
  }
}

/// Picks the implementation for the running platform.
SmsService createSmsService({
  required AppDatabase db,
  required ReconcileService reconciler,
}) {
  if (!Platform.isAndroid) return const NoopSmsService();
  return AndroidSmsService(db: db, reconciler: reconciler);
}

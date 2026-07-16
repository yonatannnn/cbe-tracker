import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/db/daos/settings_dao.dart';
import '../data/db/database_provider.dart';
import '../features/reconcile/reconcile_providers.dart';
import '../features/reports/reports_providers.dart';
import '../services/image_migration.dart';
import '../services/notification_service.dart';
import '../services/service_providers.dart';
import 'router.dart';
import 'theme.dart';

/// Root application widget.
class CbeTrackerApp extends ConsumerStatefulWidget {
  const CbeTrackerApp({super.key, this.bootstrap = true});

  /// Runs launch work: the daily report reminder and the screenshot migration.
  ///
  /// Off in widget tests, which boot neither the notification plugin nor a
  /// database — an explicit flag rather than swallowing the resulting errors,
  /// which would hide genuinely broken startup work in production.
  final bool bootstrap;

  @override
  ConsumerState<CbeTrackerApp> createState() => _CbeTrackerAppState();
}

class _CbeTrackerAppState extends ConsumerState<CbeTrackerApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.bootstrap) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _initReminder();
        _rescueScreenshots();
        _rearmSms();
        _maybeCloudBackup();
      });
    }
  }

  /// Re-arms SMS ingestion on every launch (§FR-4).
  ///
  /// startListening() was previously called exactly once, at the moment
  /// permission was granted. If the OS ever dropped the background receiver —
  /// app update, battery optimisation, force stop — nothing re-registered it,
  /// and the shadow ledger silently stopped filling while the dashboard kept
  /// claiming every message was accounted for. syncInbox() then catches up
  /// whatever arrived while nothing was listening; its unique index makes the
  /// re-read safe to repeat.
  Future<void> _rearmSms() async {
    try {
      final state = await ref
          .read(settingsDaoProvider)
          .watchSmsPermissionState()
          .first;
      if (state != SmsPermissionState.granted) return;
      final sms = ref.read(smsServiceProvider);
      if (!sms.isSupported) return;
      await sms.startListening();
      await sms.syncInbox();
    } on Object {
      // Best-effort: the Reconcile tab's manual refresh reports failures.
    }
  }

  Future<void> _reconcileQuietly() async {
    try {
      await ref.read(reconcileServiceProvider).reconcile();
    } on Object {
      // The next sweep (save, sync, resume) retries; resuming must never crash.
    }
  }

  /// Uploads a fresh cloud backup if one is due and the phone is online (Phase
  /// 10). Silent and best-effort: no project configured, signed out, offline,
  /// or too soon since the last one all just skip. Runs on launch and resume,
  /// which is when connectivity is most likely to have returned.
  Future<void> _maybeCloudBackup() async {
    final service = ref.read(cloudBackupServiceProvider);
    if (service == null) return;
    try {
      await service.maybeAutoBackup(DateTime.now());
    } on Object {
      // maybeAutoBackup already swallows its own failures; this guards the
      // provider read on the off chance the client isn't ready yet.
    }
  }

  /// Relocates screenshots that older builds left in the cache directory,
  /// where Android is free to delete them (§2).
  ///
  /// Silent: the owner never chose this, and a failure here must not block the
  /// dashboard — it retries next launch.
  Future<void> _rescueScreenshots() async {
    try {
      await ImageMigration(
        db: ref.read(appDatabaseProvider),
        store: ref.read(imageStoreProvider),
      ).run();
    } on Object {
      // Best-effort.
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
    if (state == AppLifecycleState.resumed) {
      // SMS may have arrived in the background while we were away (§FR-5).
      // Guarded: this ran unawaited on the app's hottest path, so a throw was
      // an unhandled async error.
      _reconcileQuietly();
      // A phone asleep past midnight won't have fired the rollover timer, so
      // catch the day up on resume — otherwise the dashboard's "today" and the
      // reconcile banner stay stuck on yesterday until a restart.
      ref.read(todayProvider.notifier).refresh();
      // Resuming often means connectivity is back — a good moment to catch up
      // the daily cloud backup (Phase 10).
      _maybeCloudBackup();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      // Shown in the Android task switcher; matches the launcher label.
      title: 'CBE Tracker',
      theme: AppTheme.light(),
      routerConfig: ref.watch(routerProvider),
    );
  }
}

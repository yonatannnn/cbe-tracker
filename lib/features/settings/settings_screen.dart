/// Settings: who is signed in, branches, and the daily report reminder (§FR-6).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/db/database_provider.dart';
import '../../data/profiles/profile_provider.dart';
import '../../services/service_providers.dart';
import '../../services/notification_service.dart';
import '../../services/supabase_config.dart';
import '../reports/reports_providers.dart';
import 'backup_section.dart';
import 'cloud_backup_section.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reminder = ref.watch(reminderTimeProvider).value;
    final registry = ref.watch(profilesProvider);
    final me = registry.active;
    final others = registry.profiles.where((p) => p.id != me?.id).toList();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          children: [
            const _SectionHeader('User'),
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(me?.name ?? 'Nobody signed in'),
              subtitle: const Text(
                'Branches and transactions are kept per user',
              ),
            ),
            for (final other in others)
              ListTile(
                leading: const SizedBox(width: 24),
                title: Text('Switch to ${other.name}'),
                trailing: const Icon(Icons.swap_horiz),
                onTap: () => _switchUser(context, ref, other.id),
              ),
            ListTile(
              leading: const SizedBox(width: 24),
              title: const Text('Add another user'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/welcome'),
            ),
            ListTile(
              leading: const SizedBox(width: 24),
              title: const Text('Sign out'),
              subtitle: const Text('Your data stays on this phone'),
              trailing: const Icon(Icons.logout),
              onTap: () => _signOut(context, ref),
            ),
            const Divider(),
            const _SectionHeader('Branches'),
            ListTile(
              leading: const Icon(Icons.store_outlined),
              title: const Text('Manage branches'),
              subtitle: const Text('Add, rename, archive'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/branches'),
            ),
            const Divider(),
            const _SectionHeader('Daily reminder'),
            SwitchListTile(
              secondary: const Icon(Icons.notifications_outlined),
              title: const Text('Remind me to generate reports'),
              subtitle: Text(
                reminder == null ? 'Off' : 'Every day at ${reminder.display}',
              ),
              value: reminder != null,
              onChanged: (enabled) => _toggle(context, ref, enabled: enabled),
            ),
            if (reminder != null)
              ListTile(
                leading: const SizedBox(width: 24),
                title: const Text('Reminder time'),
                trailing: Text(
                  reminder.display,
                  style: theme.textTheme.titleMedium,
                ),
                onTap: () => _pickTime(context, ref, reminder),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.xs,
                AppSpacing.lg,
                AppSpacing.lg,
              ),
              child: Text(
                'A notification at the end of the day, so a branch never goes '
                'unreported.',
                style: AppTextStyles.label.copyWith(
                  letterSpacing: 0,
                  height: 1.45,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
            // The Firestore mirror. Hidden entirely in a build without Firebase
            // config; otherwise one line of status and a Sync now.
            if (ref.watch(firebaseSyncProvider) != null) ...[
              const Divider(),
              const _SectionHeader('Cloud'),
              ListTile(
                leading: const Icon(Icons.cloud_done_outlined),
                title: const Text('Saved to the cloud on approve'),
                subtitle: Text(
                  me == null
                      ? 'Nobody signed in'
                      : 'Under your name, ${me.name}: branches, then their '
                            'transactions',
                ),
              ),
              ListTile(
                leading: const SizedBox(width: 24),
                title: const Text('Sync everything now'),
                subtitle: const Text(
                  'Pushes every branch and transaction again',
                ),
                trailing: const Icon(Icons.sync),
                onTap: () => _syncAll(context, ref),
              ),
            ],
            const Divider(),
            const _SectionHeader('Backup'),
            const BackupSection(),
            // Only when a Supabase project was wired in at build time; otherwise
            // the whole cloud feature stays hidden.
            if (SupabaseConfig.isConfigured) ...[
              const Divider(),
              const _SectionHeader('Cloud backup'),
              const CloudBackupSection(),
            ],
          ],
        ),
      ),
    );
  }

  /// Switches books. The database provider follows the profile, so every
  /// screen rebuilds on hers; going home drops the settings stack, which was
  /// built against the previous user's data.
  Future<void> _switchUser(
    BuildContext context,
    WidgetRef ref,
    String id,
  ) async {
    await ref.read(profilesProvider.notifier).switchTo(id);
    if (context.mounted) context.go('/home');
  }

  Future<void> _syncAll(BuildContext context, WidgetRef ref) async {
    final sync = ref.read(firebaseSyncProvider);
    final profile = ref.read(activeProfileProvider);
    if (sync == null || profile == null) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Syncing…')));
    final ok = await sync.syncAll(profile, ref.read(appDatabaseProvider));
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Everything is in the cloud under ${profile.name}'
              : "Couldn't reach the cloud — it will retry on the next save",
        ),
      ),
    );
  }

  /// Nobody signed in → the router's first gate shows the welcome screen.
  /// Going there explicitly (rather than waiting for the redirect) drops the
  /// settings stack, which was built against the signed-out user's data.
  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'Your branches and transactions stay on this phone. Type your name '
          'on the welcome screen to get back to them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false) || !context.mounted) return;
    await ref.read(profilesProvider.notifier).signOut();
    if (context.mounted) context.go('/welcome');
  }

  Future<void> _toggle(
    BuildContext context,
    WidgetRef ref, {
    required bool enabled,
  }) async {
    final settings = ref.read(settingsDaoProvider);
    final notifications = ref.read(notificationServiceProvider);

    if (!enabled) {
      await notifications.cancel();
      await settings.setReminderTime(null); // stores 'off'
      return;
    }

    await notifications.init();
    final granted = await notifications.requestPermission();
    if (!granted) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Notifications are blocked in system settings'),
        ),
      );
      return;
    }
    // Restore the time she had before switching off; 18:00 only on first use.
    final saved =
        ReminderTime.parse(await settings.getLastReminderTime()) ??
        ReminderTime.defaultTime;
    await settings.setReminderTime(saved.stored);
    await notifications.scheduleDaily(saved);
  }

  Future<void> _pickTime(
    BuildContext context,
    WidgetRef ref,
    ReminderTime current,
  ) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current.hour, minute: current.minute),
    );
    if (picked == null) return;

    final time = ReminderTime(picked.hour, picked.minute);
    await ref.read(settingsDaoProvider).setReminderTime(time.stored);
    await ref.read(notificationServiceProvider).scheduleDaily(time);
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    // Same quiet grey label as every other section header in the app — green
    // headers here would spend the colour that means "credit" everywhere else.
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: Text(label.toUpperCase(), style: AppTextStyles.label),
    );
  }
}

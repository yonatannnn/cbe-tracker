/// Settings: branches and the daily report reminder (§FR-6).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/db/database_provider.dart';
import '../../services/notification_service.dart';
import '../../services/supabase_config.dart';
import '../reports/reports_providers.dart';
import 'backup_section.dart';
import 'cloud_backup_section.dart';
import 'manage_branches_sheet.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reminder = ref.watch(reminderTimeProvider).value;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionHeader('Branches'),
          ListTile(
            leading: const Icon(Icons.store_outlined),
            title: const Text('Manage branches'),
            subtitle: const Text('Add, rename, archive'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showManageBranchesSheet(context),
          ),
          const Divider(),
          const _SectionHeader('Daily reminder'),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_outlined),
            title: const Text('Remind me to generate reports'),
            subtitle: Text(
              reminder == null
                  ? 'Off'
                  : 'Every day at ${reminder.display}',
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
    );
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

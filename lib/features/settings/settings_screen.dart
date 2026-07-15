/// Settings: branches and the daily report reminder (§FR-6).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database_provider.dart';
import '../../services/notification_service.dart';
import '../reports/reports_providers.dart';
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
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Text(
              'A notification at the end of the day, so a branch never goes '
              'unreported.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
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
    await settings.setReminderTime(ReminderTime.defaultTime.stored);
    await notifications.scheduleDaily(ReminderTime.defaultTime);
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
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

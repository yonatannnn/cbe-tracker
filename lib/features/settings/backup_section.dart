/// Backup: export a zip, restore from one (§9).
///
/// The phone is the only copy of the books. Everything here is written for
/// someone who will use it twice — once when she sets up a new phone, and once
/// on the worst day of the year.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/theme.dart';
import '../../data/db/database_provider.dart';
import '../../services/backup_service.dart';
import '../../services/service_providers.dart';

class BackupSection extends ConsumerStatefulWidget {
  const BackupSection({super.key});

  @override
  ConsumerState<BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends ConsumerState<BackupSection> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.ios_share_outlined),
          title: const Text('Back up now'),
          subtitle: const Text('Every transaction and screenshot, in one file'),
          enabled: !_busy,
          onTap: _export,
        ),
        ListTile(
          leading: const Icon(Icons.settings_backup_restore),
          title: const Text('Restore from a backup'),
          subtitle: const Text('Replaces everything on this phone'),
          enabled: !_busy,
          onTap: _restore,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.xs,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Text(
            'A backup is a single file. Send it to yourself — Telegram, email, '
            'anywhere off this phone. If the phone is lost, only what you '
            'backed up survives.',
            style: AppTextStyles.label.copyWith(
              letterSpacing: 0,
              height: 1.45,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
      ],
    );
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final file = await ref.read(backupServiceProvider).export();
      if (!mounted) return;
      // Straight to the share sheet: a backup sitting in a temp folder on the
      // same phone protects against nothing.
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: 'CBE Tracker backup',
        ),
      );
    } on Object catch (error) {
      _say(error is BackupException ? '$error' : "Couldn't make the backup.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    // Backups arrive through Telegram or email, so they land wherever that app
    // saved them — accept any file rather than filtering to a folder she'd
    // have to find. inspect() rejects anything that isn't really a backup.
    final picked = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Backup', extensions: ['zip'], mimeTypes: ['application/zip']),
      ],
    );
    if (picked == null || !mounted) return;

    setState(() => _busy = true);
    final service = ref.read(backupServiceProvider);
    final zip = File(picked.path);

    try {
      // Say what's inside BEFORE replacing anything: this is the one action in
      // the app that destroys data, so she confirms against real numbers
      // rather than a filename.
      final summary = await service.inspect(zip);
      if (!mounted) return;
      final confirmed = await _confirm(summary);
      if (!confirmed || !mounted) return;

      await service.restore(zip);

      // Every DAO and stream watches this provider, so rebuilding it points
      // the whole app at the restored file.
      ref.invalidate(appDatabaseProvider);
      _say('Restored. Your branches and balances are back.');
    } on Object catch (error) {
      _say(
        error is BackupException
            ? '$error'
            : "Couldn't restore that file. Nothing was changed.",
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(BackupSummary summary) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restore this backup?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('This file holds:'),
            const SizedBox(height: AppSpacing.sm),
            _Line('${summary.branches} ${_plural(summary.branches, 'branch', 'branches')}'),
            _Line('${summary.transactions} ${_plural(summary.transactions, 'transaction', 'transactions')}'),
            _Line('${summary.smsMessages} CBE ${_plural(summary.smsMessages, 'message', 'messages')}'),
            _Line('${summary.images} ${_plural(summary.images, 'screenshot', 'screenshots')}'),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Everything currently on this phone is replaced and cannot be '
              'recovered.',
              style: TextStyle(color: AppColors.debit, height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.debit),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Replace everything'),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  static String _plural(int n, String one, String many) => n == 1 ? one : many;

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _Line extends StatelessWidget {
  const _Line(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text('• $text'),
    );
  }
}

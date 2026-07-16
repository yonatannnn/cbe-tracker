/// Cloud backup: sign in, and an off-device copy that keeps itself current
/// (Phase 10).
///
/// Shown only when a Supabase project was wired in at build time. Signed out,
/// it invites a sign-in; signed in, it reports when the last backup ran and
/// offers a manual backup, a restore, and sign-out. The automatic daily upload
/// happens on app launch — this section is the visible half of it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/db/database_provider.dart';
import '../../services/cloud_backup_service.dart';
import '../../services/service_providers.dart';

class CloudBackupSection extends ConsumerStatefulWidget {
  const CloudBackupSection({super.key});

  @override
  ConsumerState<CloudBackupSection> createState() => _CloudBackupSectionState();
}

class _CloudBackupSectionState extends ConsumerState<CloudBackupSection> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(cloudBackupServiceProvider);
    final email = ref.watch(cloudAuthEmailProvider).value;

    // Should never render otherwise (settings gates on isConfigured), but stay
    // safe if it does.
    if (service == null) return const SizedBox.shrink();

    final children = <Widget>[
      if (email == null)
        ListTile(
          leading: const Icon(Icons.cloud_outlined),
          title: const Text('Sign in for cloud backup'),
          subtitle: const Text('An off-device copy, updated every day'),
          enabled: !_busy,
          onTap: _signInFlow,
        )
      else ...[
        ListTile(
          leading: const Icon(Icons.cloud_done_outlined),
          title: Text('Signed in as $email'),
          subtitle: _LastBackupLine(service: service),
        ),
        ListTile(
          leading: const Icon(Icons.backup_outlined),
          title: const Text('Back up now'),
          subtitle: const Text('Upload the latest copy'),
          enabled: !_busy,
          onTap: _backupNow,
        ),
        ListTile(
          leading: const Icon(Icons.cloud_download_outlined),
          title: const Text('Restore from cloud'),
          subtitle: const Text('Replaces everything on this phone'),
          enabled: !_busy,
          onTap: _restore,
        ),
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('Sign out'),
          enabled: !_busy,
          onTap: _signOut,
        ),
      ],
      Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.xs,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        child: Text(
          'A copy uploads automatically each day when you open the app online. '
          'If this phone is lost, sign in on a new one and restore.',
          style: AppTextStyles.label.copyWith(
            letterSpacing: 0,
            height: 1.45,
            fontWeight: FontWeight.w400,
          ),
        ),
      ),
      if (_busy) const LinearProgressIndicator(minHeight: 2),
    ];

    return Column(children: children);
  }

  Future<void> _signInFlow() async {
    final credentials = await showModalBottomSheet<_Credentials>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _SignInSheet(),
    );
    if (credentials == null || !mounted) return;

    setState(() => _busy = true);
    final service = ref.read(cloudBackupServiceProvider)!;
    try {
      if (credentials.isNew) {
        await service.signUp(credentials.email, credentials.password);
        // Depending on the project's email-confirmation setting, sign-up may
        // not create a session; sign in to be sure.
        if (!service.isSignedIn) {
          await service.signIn(credentials.email, credentials.password);
        }
      } else {
        await service.signIn(credentials.email, credentials.password);
      }
      if (service.isSignedIn) {
        _say('Signed in. Your first backup will upload shortly.');
      } else {
        _say('Check your email to confirm the account, then sign in.');
      }
    } on Object catch (error) {
      _say(_message(error, "Couldn't sign in."));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _backupNow() async {
    setState(() => _busy = true);
    final service = ref.read(cloudBackupServiceProvider)!;
    try {
      await service.backupNow(DateTime.now());
      _say('Backed up to the cloud.');
    } on Object catch (error) {
      _say(_message(error, "Couldn't back up. Check your connection."));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restore from cloud?'),
        content: Text(
          'This downloads your most recent cloud backup and replaces '
          'everything currently on this phone. It cannot be undone.',
          style: TextStyle(color: AppColors.debit, height: 1.4),
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
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final service = ref.read(cloudBackupServiceProvider)!;
    try {
      await service.restoreLatest();
      // Every DAO and stream watches this provider, so rebuilding it points the
      // whole app at the restored file.
      ref.invalidate(appDatabaseProvider);
      _say('Restored from your latest cloud backup.');
    } on Object catch (error) {
      _say(_message(error, "Couldn't restore. Nothing was changed."));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await ref.read(cloudBackupServiceProvider)!.signOut();
      _say('Signed out. Automatic backups are paused.');
    } on Object {
      _say("Couldn't sign out.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _message(Object error, String fallback) =>
      error is CloudBackupException ? '$error' : fallback;

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// The "Last backup …" subtitle, resolved from the stored timestamp.
class _LastBackupLine extends StatelessWidget {
  const _LastBackupLine({required this.service});

  final CloudBackupService service;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DateTime?>(
      future: service.lastBackupAt(),
      builder: (context, snapshot) {
        final when = snapshot.data;
        return Text(when == null ? 'No backup yet' : 'Last backup ${_ago(when)}');
      },
    );
  }

  static String _ago(DateTime when) {
    final diff = DateTime.now().difference(when);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

class _Credentials {
  const _Credentials({
    required this.email,
    required this.password,
    required this.isNew,
  });

  final String email;
  final String password;
  final bool isNew;
}

/// Email + password entry, with sign-in and create-account as the two exits.
class _SignInSheet extends StatefulWidget {
  @override
  State<_SignInSheet> createState() => _SignInSheetState();
}

class _SignInSheetState extends State<_SignInSheet> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Cloud backup', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.md),
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Email'),
              validator: (v) =>
                  (v != null && v.contains('@')) ? null : 'Enter your email',
            ),
            const SizedBox(height: AppSpacing.sm),
            TextFormField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
              validator: (v) =>
                  (v != null && v.length >= 6) ? null : 'At least 6 characters',
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              onPressed: () => _submit(isNew: false),
              child: const Text('Sign in'),
            ),
            const SizedBox(height: AppSpacing.xs),
            TextButton(
              onPressed: () => _submit(isNew: true),
              child: const Text('Create an account'),
            ),
          ],
        ),
      ),
    );
  }

  void _submit({required bool isNew}) {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      _Credentials(
        email: _email.text.trim(),
        password: _password.text,
        isNew: isNew,
      ),
    );
  }
}

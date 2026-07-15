/// Full-screen SMS explainer shown BEFORE the system dialog (§FR-4).
///
/// Asking for SMS access with no context is how apps get denied. This says
/// plainly what is read and what is not, and offers a first-class way out.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/daos/settings_dao.dart';
import '../../data/db/database_provider.dart';
import 'reconcile_providers.dart';

class SmsPermissionExplainer extends ConsumerStatefulWidget {
  const SmsPermissionExplainer({super.key});

  @override
  ConsumerState<SmsPermissionExplainer> createState() =>
      _SmsPermissionExplainerState();
}

class _SmsPermissionExplainerState
    extends ConsumerState<SmsPermissionExplainer> {
  bool _busy = false;

  Future<void> _allow() async {
    setState(() => _busy = true);
    final sms = ref.read(smsServiceProvider);

    final granted = await sms.requestPermission();
    if (!granted) {
      // Denied at the system level → same as skipping (§FR-4).
      await ref
          .read(settingsDaoProvider)
          .setSmsPermissionState(SmsPermissionState.skipped);
      if (!mounted) return;
      setState(() => _busy = false);
      return;
    }

    await ref
        .read(settingsDaoProvider)
        .setSmsPermissionState(SmsPermissionState.granted);
    await sms.syncInbox();
    await sms.startListening();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<void> _skip() => ref
      .read(settingsDaoProvider)
      .setSmsPermissionState(SmsPermissionState.skipped);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Spacer(),
            Icon(
              Icons.sms_outlined,
              size: 56,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 20),
            Text(
              'Cross-check with CBE messages',
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              'CBE texts you every time money moves. Reading those lets the '
              'app tell you when a payment arrived but no screenshot was '
              'added — so nothing goes unrecorded.',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            const _Point(
              icon: Icons.check_circle_outline,
              text: 'Only messages from CBE are read',
            ),
            const _Point(
              icon: Icons.phone_android_outlined,
              text: 'They stay on this phone — nothing is uploaded',
            ),
            const _Point(
              icon: Icons.account_balance_wallet_outlined,
              text: 'Messages never change your balances; screenshots do',
            ),
            const Spacer(),
            FilledButton(
              onPressed: _busy ? null : _allow,
              child: _busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Allow'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy ? null : _skip,
              child: const Text('Skip — screenshots only'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.outline),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

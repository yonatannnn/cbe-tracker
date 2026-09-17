/// Welcome: the app's first screen asks who is using it.
///
/// The name is the key everything is filed under — her branches, balances and
/// screenshots live in a folder of their own, so two people sharing a phone
/// never see each other's books. Typing a name that already exists signs
/// that person back in rather than starting a second, empty set of books.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/profiles/profile_provider.dart';

class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  final _controller = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canContinue => _controller.text.trim().isNotEmpty && !_busy;

  Future<void> _continue() async {
    if (!_canContinue) return;
    setState(() => _busy = true);
    try {
      await ref.read(profilesProvider.notifier).enter(_controller.text);
    } on Object {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't save your name. Try again.")),
      );
      return;
    }
    if (!mounted) return;
    // The router's gate takes it from here: no branches yet → onboarding,
    // otherwise straight to her dashboard.
    context.go('/home');
  }

  Future<void> _switchTo(String id) async {
    setState(() => _busy = true);
    await ref.read(profilesProvider.notifier).switchTo(id);
    if (!mounted) return;
    context.go('/home');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final registry = ref.watch(profilesProvider);
    final others = registry.profiles;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Icon(
                Icons.account_balance_outlined,
                size: 48,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('Welcome', style: theme.textTheme.headlineMedium),
              const SizedBox(height: AppSpacing.sm),
              Text(
                "What's your name? Your branches and transactions are kept "
                'under it, separate from anyone else using this phone.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              TextField(
                controller: _controller,
                autofocus: true,
                enabled: !_busy,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Your name',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _continue(),
              ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton(
                onPressed: _canContinue ? _continue : null,
                child: _busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Continue'),
              ),
              if (others.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xl),
                Text(
                  'Or continue as',
                  style: AppTextStyles.label.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    for (final profile in others)
                      ActionChip(
                        avatar: const Icon(Icons.person_outline, size: 18),
                        label: Text(profile.name),
                        onPressed: _busy ? null : () => _switchTo(profile.id),
                      ),
                  ],
                ),
              ],
              const Spacer(flex: 2),
            ],
          ),
        ),
      ),
    );
  }
}

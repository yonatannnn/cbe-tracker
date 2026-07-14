# CBE Branch Expense Tracker

Read REQUIREMENTS.md before doing anything. It is the source of truth.

## Rules
- Work ONE phase at a time from §8. Never start the next phase unless I say so.
- Every phase must compile (`flutter analyze` clean) and its tests pass
  (`flutter test`) before you report it done.
- Money is integer cents everywhere. Never double arithmetic for balances.
- The CBE parser stays pure Dart — no Flutter imports in core/parser/.
- Don't add packages beyond §5 without asking me.

## Commands
- Run tests: flutter test
- Static check: flutter analyze
- Run on device: flutter run
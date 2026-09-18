/// Manual amount/reference form — the fallback for unreadable images (§FR-2)
/// and the inline editor for AI-parsed / failed bulk rows (§FR-3).
///
/// There is no credit/debit choice: every receipt she files is a customer
/// paying in, so every transaction is money in.
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/money/etb_format.dart';

class ManualEntryFields extends StatefulWidget {
  const ManualEntryFields({
    super.key,
    required this.onAmountChanged,
    required this.onReferenceChanged,
    this.initialCents,
    this.initialReference = '',
    this.amountError,
    this.dense = false,
  });

  /// Emits parsed cents, or null when the box is empty/invalid — the caller
  /// treats null as "not saveable" rather than guessing a number.
  final ValueChanged<int?> onAmountChanged;
  final ValueChanged<String> onReferenceChanged;

  final int? initialCents;
  final String initialReference;
  final String? amountError;

  /// Tighter layout for bulk review rows.
  final bool dense;

  @override
  State<ManualEntryFields> createState() => _ManualEntryFieldsState();
}

class _ManualEntryFieldsState extends State<ManualEntryFields> {
  late final TextEditingController _amount = TextEditingController(
    text: widget.initialCents == null ? '' : centsToInput(widget.initialCents!),
  );
  late final TextEditingController _reference = TextEditingController(
    text: widget.initialReference,
  );
  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gap = widget.dense ? 8.0 : 12.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Amount (ETB)',
            border: const OutlineInputBorder(),
            isDense: widget.dense,
            errorText: widget.amountError,
          ),
          onChanged: (value) => widget.onAmountChanged(parseCentsInput(value)),
        ),
        SizedBox(height: gap),
        TextField(
          controller: _reference,
          decoration: InputDecoration(
            labelText: 'Reference (optional)',
            helperText: 'Left blank, a MANUAL- reference is generated',
            border: const OutlineInputBorder(),
            isDense: widget.dense,
          ),
          style: AppTextStyles.mono,
          onChanged: widget.onReferenceChanged,
        ),
      ],
    );
  }
}

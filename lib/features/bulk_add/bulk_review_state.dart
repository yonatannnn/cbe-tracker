/// Pure state for the bulk review modal (§FR-3).
///
/// No Flutter, no database — just the rules about what is checked, what may be
/// checked, and what the save button says. Kept separate so the tricky bits
/// (defaults per status, the live count, a failed row becoming checkable once
/// filled in) are testable without pumping a widget.
library;

import '../../core/ids.dart';
import '../../core/parser/cbe_parser.dart';
import '../../services/bulk_processor.dart';

/// One row in the review list.
class ReviewRow {
  const ReviewRow({
    required this.item,
    required this.checked,
    this.editedCents,
    this.editedType,
    this.editedReference,
    this.expanded = false,
  });

  final BulkItem item;
  final bool checked;

  /// Manual overrides. Null means "use whatever was parsed".
  final int? editedCents;
  final TxType? editedType;
  final String? editedReference;

  /// Whether the inline edit form is showing.
  final bool expanded;

  BulkStatus get status => item.status;

  /// Duplicates can never be saved — the reference is already recorded.
  bool get isDuplicate => status == BulkStatus.duplicate;

  int? get effectiveCents => editedCents ?? item.parsed?.amountCents;

  TxType? get effectiveType => editedType ?? item.parsed?.type;

  /// The reference to save with. Falls back to `MANUAL-<uuid>` when neither
  /// the parse nor the user supplied one (§FR-2 keeps references UNIQUE).
  String effectiveReference() {
    final edited = editedReference?.trim();
    if (edited != null && edited.isNotEmpty) return edited;
    final parsed = item.parsed?.reference;
    if (parsed != null && parsed.isNotEmpty) return parsed;
    return manualReference();
  }

  /// A row may be checked once it has an amount and a type, and isn't a
  /// duplicate. This is what turns a filled-in failed row into a saveable one.
  bool get isCheckable {
    if (isDuplicate) return false;
    final cents = effectiveCents;
    return cents != null && cents > 0 && effectiveType != null;
  }

  /// Only AI-parsed and failed rows are editable. A clean local parse is shown
  /// read-only — automation first (§FR-3).
  bool get isEditable =>
      status == BulkStatus.okAiParsed || status == BulkStatus.failed;

  ReviewRow copyWith({
    bool? checked,
    TxType? editedType,
    String? editedReference,
    bool? expanded,
  }) {
    return ReviewRow(
      item: item,
      checked: checked ?? this.checked,
      editedCents: editedCents,
      editedType: editedType ?? this.editedType,
      editedReference: editedReference ?? this.editedReference,
      expanded: expanded ?? this.expanded,
    );
  }

  /// Replaces the manual amount; null genuinely clears it.
  ReviewRow withAmount(int? cents) => ReviewRow(
    item: item,
    checked: checked,
    editedCents: cents,
    editedType: editedType,
    editedReference: editedReference,
    expanded: expanded,
  );
}

/// Whole-modal state.
class ReviewState {
  const ReviewState({required this.rows});

  /// Applies the per-status defaults (§FR-3):
  ///  * ok            → checked (trust the local parser)
  ///  * okAiParsed    → UNCHECKED (the user must look at the amount first)
  ///  * duplicate     → never checked
  ///  * failed        → unchecked until filled in
  factory ReviewState.initial(List<BulkItem> items) {
    return ReviewState(
      rows: [
        for (final item in items)
          ReviewRow(item: item, checked: item.status == BulkStatus.ok),
      ],
    );
  }

  final List<ReviewRow> rows;

  int get checkedCount => rows.where((r) => r.checked).length;

  List<ReviewRow> get checkedRows =>
      rows.where((r) => r.checked).toList(growable: false);

  bool get canSave => checkedCount > 0;

  /// Live label — states the exact count (§FR-3).
  String get saveLabel => checkedCount == 1
      ? 'Save 1 transaction'
      : 'Save $checkedCount transactions';

  int get duplicateCount =>
      rows.where((r) => r.status == BulkStatus.duplicate).length;

  int get failedCount => rows.where((r) => r.status == BulkStatus.failed).length;

  ReviewState _replace(int index, ReviewRow row) {
    final next = List<ReviewRow>.of(rows);
    next[index] = row;
    return ReviewState(rows: next);
  }

  /// Toggles a row. Rows that aren't checkable can't be turned on.
  ReviewState toggle(int index, {required bool checked}) {
    final row = rows[index];
    if (checked && !row.isCheckable) return this;
    return _replace(index, row.copyWith(checked: checked));
  }

  ReviewState setExpanded(int index, {required bool expanded}) =>
      _replace(index, rows[index].copyWith(expanded: expanded));

  /// Sets (or clears, with null) the manual amount.
  ///
  /// Edits are per-field rather than one `edit({cents, type, reference})`: a
  /// combined setter can't tell "leave unchanged" from "clear to null", so
  /// emptying the amount box would silently keep the previous value and leave
  /// the row checkable.
  ReviewState editAmount(int index, int? cents) =>
      _settle(index, rows[index].withAmount(cents));

  ReviewState editType(int index, TxType type) =>
      _settle(index, rows[index].copyWith(editedType: type));

  ReviewState editReference(int index, String reference) =>
      _settle(index, rows[index].copyWith(editedReference: reference));

  /// Re-derives `checked` after an edit: a row that has become valid is checked
  /// automatically (filling in a failed row IS the user asking to save it,
  /// §FR-3), and one that has become invalid is unchecked so it can't slip
  /// into the batch.
  ReviewState _settle(int index, ReviewRow row) =>
      _replace(index, row.copyWith(checked: row.isCheckable));
}

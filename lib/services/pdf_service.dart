/// Per-branch and combined report PDFs (§6, FR-6).
library;

import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/money/etb_format.dart';
import '../core/parser/cbe_parser.dart';
import 'report_service.dart';

/// Fonts for the document.
///
/// DejaVu is EMBEDDED rather than relying on the pdf package's built-in
/// Helvetica or on a device font. Helvetica is WinAnsi-encoded and has no
/// U+2212 MINUS SIGN — the exact character [formatSignedCents] puts on every
/// debit line, which would render as a blank box. (NotoSans is missing it too;
/// verified before choosing.)
class _ReportFonts {
  const _ReportFonts({required this.regular, required this.bold});

  final pw.Font regular;
  final pw.Font bold;

  static Future<_ReportFonts> load() async {
    return _ReportFonts(
      regular: pw.Font.ttf(
        await rootBundle.load('assets/fonts/DejaVuSans.ttf'),
      ),
      bold: pw.Font.ttf(
        await rootBundle.load('assets/fonts/DejaVuSans-Bold.ttf'),
      ),
    );
  }
}

class PdfService {
  PdfService({this.businessName = 'CBE Branch Tracker'});

  /// Printed as the document title.
  final String businessName;

  /// One PDF covering every branch that moved money.
  Future<File> buildCombined(DailyReport report) async {
    final fonts = await _ReportFonts.load();
    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: fonts.regular, bold: fonts.bold),
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (context) => [
          _title(report.day, 'All branches'),
          pw.SizedBox(height: 16),
          _overallSummary(report),
          pw.SizedBox(height: 20),
          for (final branch in report.activeBranches) ...[
            _branchSection(branch),
            pw.SizedBox(height: 18),
          ],
          if (report.activeBranches.isEmpty)
            pw.Text('No transactions were recorded on this day.'),
          pw.SizedBox(height: 8),
          _footer(report.footer),
        ],
      ),
    );

    return _write(doc, 'AllBranches_${_fileDate(report.day)}.pdf');
  }

  /// One PDF for a single branch.
  Future<File> buildForBranch(
    BranchDayReport branch,
    DateTime day,
    ReconciliationFooter footer,
  ) async {
    final fonts = await _ReportFonts.load();
    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: fonts.regular, bold: fonts.bold),
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (context) => [
          _title(day, branch.branch.name),
          pw.SizedBox(height: 16),
          _branchSection(branch),
          pw.SizedBox(height: 12),
          _footer(footer),
        ],
      ),
    );

    // The branch id, not just the name, decides the filename. _safeName keeps
    // only [A-Za-z0-9], so every Amharic name (ቦሌ, ፒያሳ, መገናኛ) sanitises to the
    // empty string and falls back to the same literal 'Branch' — and names are
    // not unique in the schema anyway. Sharing per-branch reports writes them
    // all into one temp directory, so a shared filename means each PDF silently
    // overwrites the last and every manager is handed the same branch's
    // figures. The id makes collision impossible.
    return _write(
      doc,
      '${_safeName(branch.branch.name)}-${branch.branch.id}_'
      '${_fileDate(day)}.pdf',
    );
  }

  // ── pieces ───────────────────────────────────────────────────────────────

  pw.Widget _title(DateTime day, String scope) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          businessName,
          style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          'Daily report — $scope',
          style: const pw.TextStyle(fontSize: 12),
        ),
        pw.Text(
          _longDate(day),
          style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700),
        ),
        pw.Divider(),
      ],
    );
  }

  pw.Widget _overallSummary(DailyReport report) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: PdfColors.grey100,
        borderRadius: pw.BorderRadius.circular(4),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          _stat('Branches', '${report.activeBranches.length}'),
          _stat('Transactions', '${report.totalTransactionCount}'),
          _stat('Credited', formatCents(report.totalCreditedCents)),
          _stat('Debited', formatCents(report.totalDebitedCents)),
          _stat('Closing', formatCents(report.totalClosingCents), bold: true),
        ],
      ),
    );
  }

  pw.Widget _stat(String label, String value, {bool bold = false}) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          label,
          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          value,
          style: pw.TextStyle(
            fontSize: 10,
            fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
          ),
        ),
      ],
    );
  }

  pw.Widget _branchSection(BranchDayReport branch) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              branch.branch.name,
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
            ),
            pw.Text(
              '${branch.verificationLabel} verified',
              style: pw.TextStyle(
                fontSize: 9,
                color: branch.isFullyVerified
                    ? PdfColors.green800
                    : PdfColors.orange800,
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 6),
        _figuresTable(branch),
        pw.SizedBox(height: 10),
        if (branch.transactions.isEmpty)
          pw.Text(
            'No transactions.',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
          )
        else
          _transactionsTable(branch),
      ],
    );
  }

  pw.Widget _figuresTable(BranchDayReport branch) {
    final s = branch.summary;
    return pw.TableHelper.fromTextArray(
      headers: const ['Opening', 'Credited', 'Debited', 'Closing', 'Count'],
      data: [
        [
          formatCents(s.openingCents),
          formatCents(s.creditedCents),
          formatCents(s.debitedCents),
          formatCents(s.closingCents),
          '${s.txCount}',
        ],
      ],
      headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
      cellStyle: const pw.TextStyle(fontSize: 9),
      headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
      // Money reads down the column, so right-align everything but the count.
      cellAlignments: {
        0: pw.Alignment.centerRight,
        1: pw.Alignment.centerRight,
        2: pw.Alignment.centerRight,
        3: pw.Alignment.centerRight,
        4: pw.Alignment.center,
      },
      headerAlignments: {
        0: pw.Alignment.centerRight,
        1: pw.Alignment.centerRight,
        2: pw.Alignment.centerRight,
        3: pw.Alignment.centerRight,
        4: pw.Alignment.center,
      },
    );
  }

  pw.Widget _transactionsTable(BranchDayReport branch) {
    return pw.TableHelper.fromTextArray(
      headers: const ['Time', 'Amount', 'Reference', 'SMS'],
      data: [
        for (final row in branch.transactions)
          [
            _time(row.transaction.transactionDate),
            formatSignedCents(
              row.transaction.type == TxType.credit
                  ? row.transaction.amountCents
                  : -row.transaction.amountCents,
            ),
            row.transaction.reference,
            row.isVerified ? 'verified' : '—',
          ],
      ],
      headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
      cellStyle: const pw.TextStyle(fontSize: 8),
      headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
      cellAlignments: {
        0: pw.Alignment.centerLeft,
        1: pw.Alignment.centerRight,
        2: pw.Alignment.centerLeft,
        3: pw.Alignment.center,
      },
      columnWidths: {
        0: const pw.FlexColumnWidth(1.2),
        1: const pw.FlexColumnWidth(2),
        2: const pw.FlexColumnWidth(3),
        3: const pw.FlexColumnWidth(1.3),
      },
    );
  }

  pw.Widget _footer(ReconciliationFooter footer) {
    // A PDF gets forwarded — its reader can't ask what "0 unresolved" means.
    // When the SMS cross-check never ran, printing counts would present an
    // unchecked day as a verified one.
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Divider(),
        pw.Text(
          footer.crossChecked
              ? '${footer.personalCount} SMS marked personal · '
                    '${footer.unresolvedCount} unresolved'
              : 'SMS cross-check not active — screenshot records only',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
        ),
      ],
    );
  }

  // ── output ───────────────────────────────────────────────────────────────

  Future<File> _write(pw.Document doc, String fileName) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(await doc.save(), flush: true);
    return file;
  }

  static String _fileDate(DateTime day) =>
      '${day.year}-${_two(day.month)}-${_two(day.day)}';

  /// Keeps a branch name usable as a filename.
  static String _safeName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-');
    final trimmed = cleaned.replaceAll(RegExp(r'^-+|-+$'), '');
    return trimmed.isEmpty ? 'Branch' : trimmed;
  }

  static const List<String> _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  static String _longDate(DateTime day) =>
      '${_months[day.month - 1]} ${day.day}, ${day.year}';

  static String _time(DateTime moment) =>
      '${_two(moment.hour)}:${_two(moment.minute)}';

  static String _two(int value) => value.toString().padLeft(2, '0');
}

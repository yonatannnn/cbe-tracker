/// Receipt templates beyond the CBE SMS: the CBE app and USSD confirmations,
/// and the receipts customers send from other banks and wallets (telebirr,
/// Awash, Bank of Abyssinia, Dashen, Zemen). Pure Dart — no Flutter imports.
///
/// Every template was taken from a real receipt or SMS (September 2026), see
/// the fixtures in test/. The rules for DIRECTION are the important part:
///
///  * The user banks with CBE only. A receipt from ANOTHER bank or wallet can
///    only be a customer paying her, so it is a credit. When the receipt
///    names the receiving bank, it must be CBE for that to hold; a telebirr
///    "You have transferred" SMS names no bank, so it is a credit at LOW
///    confidence (she checks the row).
///  * A CBE app receipt ("ETB 1,000.00 has been debited from A ETB-4351 for
///    B ETB-7737") and a CBE USSD confirmation ("Completed ETB300.61 transfer
///    From A to B-7737") are the SENDER's screen. Whether that is her sending
///    or a customer paying her is decided by her account suffix (Settings →
///    "My CBE account ends with"): receiver matches → credit, sender matches
///    → debit, unknown → credit at LOW confidence.
///  * Her own CBE SMS ("your Account … has been Credited/Debited", "You have
///    received", "A debit transaction of", "You have successfully
///    transferred") keep the original parser and its keyword rules.
///
/// Amounts exclude charges, VAT and fee-inclusive totals, as before (§4).
library;

import 'amount_adjacency.dart';
import 'cbe_parser.dart';

/// Parses any supported receipt or SMS text. Tries the bank templates first,
/// then falls back to the CBE SMS parser; throws [ParseException] when none
/// finds an amount.
///
/// [ownerAccountSuffix] is the last digits of the user's CBE account (as
/// printed on receipts: "ETB-7737" / "…-7737" → "7737"), or null when not set.
ParsedCbeMessage parseReceiptText(String raw, {String? ownerAccountSuffix}) {
  final text = normalizeCbeText(raw);
  if (text.isEmpty) throw ParseException('Empty message');

  final suffix = _cleanSuffix(ownerAccountSuffix);
  for (final template in _templates) {
    final parsed = template(text, suffix);
    if (parsed != null) return parsed;
  }
  return parseCbeText(raw);
}

/// The templates, most specific first. Each returns null when its markers are
/// absent, so an unrelated text falls through untouched.
final List<ParsedCbeMessage? Function(String text, String? suffix)> _templates =
    [
      _cbeAppReceipt,
      _cbeUssdConfirmation,
      _telebirrSms,
      _telebirrAppReceipt,
      _transferSuccessSms, // before Awash: its link says "awashbank"
      _awashReceipt,
      _boaReceipt,
      _dashenReceipt,
    ];

String? _cleanSuffix(String? raw) {
  if (raw == null) return null;
  final digits = raw.replaceAll(RegExp(r'\D'), '');
  return digits.isEmpty ? null : digits;
}

/// Whether an account fragment printed on a receipt ("ETB-7737",
/// "1000563647737", "1****9702") ends with the user's suffix.
bool _endsWithSuffix(String? printed, String? suffix) {
  if (printed == null || suffix == null) return false;
  final digits = printed.replaceAll(RegExp(r'\D'), '');
  return digits.length >= suffix.length && digits.endsWith(suffix);
}

/// Direction for a sender's-screen CBE receipt, from the two account
/// fragments on it. Null when the suffix settles nothing.
TxType? _directionBySuffix({
  required String? senderAccount,
  required String? receiverAccount,
  required String? suffix,
}) {
  if (_endsWithSuffix(receiverAccount, suffix)) return TxType.credit;
  if (_endsWithSuffix(senderAccount, suffix)) return TxType.debit;
  return null;
}

String _clean(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Cents from an amount as OCR reads it. Besides the usual shapes this
/// accepts a decimal COMMA ("300,61" — ML Kit reads the dot on a phone screen
/// as a comma) when the comma is followed by exactly two digits at the end.
int? _cents(String raw) {
  var text = raw.trim();
  if (RegExp(r'^\d+,\d{2}$').hasMatch(text)) {
    text = text.replaceFirst(',', '.');
  }
  return centsFromText(text);
}

/// Whether the receipt names CBE anywhere. On a customer's receipt from
/// another bank or wallet, the only bank named is the one the money went TO,
/// so a text-wide check is what column-ordered OCR (labels first, values
/// after) leaves us; "Commercial B…" under a stamp still counts.
final _cbeAnywhereRe = RegExp(
  r'Commercial\s*(?:B|Bank)|\bCBE\b',
  caseSensitive: false,
);
bool _mentionsCbe(String text) => _cbeAnywhereRe.hasMatch(text);

/// A 10-character transaction number with both letters and digits — the
/// telebirr shape ("DIH7T421XV"). Dates, amounts and names never match.
final _tokenTenRe = RegExp(
  r'\b(?=[A-Z0-9]{10}\b)(?=[A-Z0-9]*[A-Z])(?=[A-Z0-9]*\d)[A-Z0-9]{10}\b',
);

/// Two to five ALL-CAPS words — how the banks print a customer's name, and
/// how OCR keeps it apart from the Title Case labels around it.
const _notNameWord = r'(?!(?:ETB|VAT|EDRRF|IPS|USD|AM|PM|QR)\b)';
final _capsNameRe = RegExp(
  '\\b($_notNameWord[A-Z]{3,}(?:\\s+$_notNameWord[A-Z]{2,}){1,4})\\b',
);

// ── CBE mobile app transfer receipt (the purple "Thank you" screen) ─────────
//
// "ETB 1,000.00 has been debited from Getu Tolosa Tola ETB-4351 for Sosina
//  Tilahun Getachew ETB-7737 on Sep 15, 2026 03:38 PM with transaction ID:
//  FT26258GYG1C. Reason: MB Transfer. Total Amount Debited: ETB1000.61 …"

final _cbeAppRe = RegExp(
  r'ETB\s*([\d,]+(?:\.\d{1,2})?)\s+has been debited from\s+(.+?)\s+ETB-?(\d{3,})\s+for\s+(.+?)\s+ETB-?(\d{3,})\s+on\s+(.+?)\s+with transaction\s*ID:?\s*(FT\w{10})',
  caseSensitive: false,
);

ParsedCbeMessage? _cbeAppReceipt(String text, String? suffix) {
  final m = _cbeAppRe.firstMatch(text);
  if (m == null) return null;
  final cents = _cents(m.group(1)!);
  if (cents == null) return null;
  final sender = _clean(m.group(2)!);
  final senderAccount = m.group(3);
  final receiver = _clean(m.group(4)!);
  final receiverAccount = m.group(5);
  final date = parseReceiptDate(m.group(6)!);
  final direction = _directionBySuffix(
    senderAccount: senderAccount,
    receiverAccount: receiverAccount,
    suffix: suffix,
  );
  final type = direction ?? TxType.credit;
  return ParsedCbeMessage(
    amountCents: cents,
    type: type,
    reference: m.group(7)!.toUpperCase(),
    date: date,
    confidence: direction == null || date == null
        ? Confidence.low
        : Confidence.high,
    rawText: text,
    bank: 'CBE',
    counterparty: type == TxType.credit ? sender : receiver,
  );
}

// ── CBE USSD (*889#) confirmation ───────────────────────────────────────────
//
// "Completed ETB300.61 transfer From Mastewal Molla Aynalem to Sosina Tilahun
//  Getachew-7737. To kgj on 16/09/2026 FT26259194Y1 Service Charge"

final _cbeUssdRe = RegExp(
  r'Completed\s+ETB\s*([\d,]+(?:\.\d{1,2})?)\s+transfer\s+From\s+(.+?)\s+to\s+(.+?)-(\d{3,})\b',
  caseSensitive: false,
);
final _ussdDateRe = RegExp(
  r'\bon\s+(\d{1,2}/\d{1,2}/\d{4})(?:\s+(\d{1,2}:\d{2}(?::\d{2})?))?',
);
final _ftRe = RegExp(r'\bFT\w{10}\b');

ParsedCbeMessage? _cbeUssdConfirmation(String text, String? suffix) {
  final m = _cbeUssdRe.firstMatch(text);
  if (m == null) return null;
  final cents = _cents(m.group(1)!);
  if (cents == null) return null;
  final sender = _clean(m.group(2)!);
  final receiver = _clean(m.group(3)!);
  final receiverAccount = m.group(4);
  final dateMatch = _ussdDateRe.firstMatch(text);
  final date = dateMatch == null
      ? null
      : parseReceiptDate(
          '${dateMatch.group(1)} ${dateMatch.group(2) ?? ''}'.trim(),
        );
  final reference = _ftRe.firstMatch(text)?.group(0)?.toUpperCase();
  // The USSD text shows only the receiver's suffix.
  final direction = _directionBySuffix(
    senderAccount: null,
    receiverAccount: receiverAccount,
    suffix: suffix,
  );
  final type = direction ?? TxType.credit;
  return ParsedCbeMessage(
    amountCents: cents,
    type: type,
    reference: reference,
    date: date,
    confidence: direction == null || reference == null || date == null
        ? Confidence.low
        : Confidence.high,
    rawText: text,
    bank: 'CBE',
    counterparty: type == TxType.credit ? sender : receiver,
  );
}

// ── telebirr SMS (from short code 127) ──────────────────────────────────────
//
// "You have received ETB 50.00 from hayat rahmeto(2519****8938) 100504 on
//  11/09/2026 21:59:18. Your transaction number is DIB6NHE3H2. Your current
//  E-Money Account balance is ETB 105.50."
// "Dear Ephrem You have transferred ETB 600.00 to asefa aynalem on 31/05/2026.
//  Your transaction number is DEV6HKJX7K."

final _telebirrSmsRe = RegExp(
  r'You have (received|transferred)\s+ETB\s*([\d,]+(?:\.\d{1,2})?)\s+(?:from|to)\s+(.+?)\s*(?:\(|\bon\b)',
  caseSensitive: false,
);
final _telebirrRefRe = RegExp(
  r'transaction number is\s*([A-Z0-9]{10})',
  caseSensitive: false,
);
final _telebirrSmsDateRe = RegExp(
  r'\bon\s+(\d{1,2}/\d{1,2}/\d{4})(?:\s+(\d{1,2}:\d{2}(?::\d{2})?))?',
);

ParsedCbeMessage? _telebirrSms(String text, String? suffix) {
  final m = _telebirrSmsRe.firstMatch(text);
  if (m == null) return null;
  final ref = _telebirrRefRe.firstMatch(text)?.group(1)?.toUpperCase();
  if (ref == null) return null; // not a telebirr SMS after all
  final cents = _cents(m.group(2)!);
  if (cents == null) return null;
  final received = m.group(1)!.toLowerCase() == 'received';
  final dateMatch = _telebirrSmsDateRe.firstMatch(text);
  final date = dateMatch == null
      ? null
      : parseReceiptDate(
          '${dateMatch.group(1)} ${dateMatch.group(2) ?? ''}'.trim(),
        );
  // "received" is money in, always. "transferred" is a customer's own SMS
  // forwarded to her — a credit — but nothing on it names her, so LOW.
  return ParsedCbeMessage(
    amountCents: cents,
    type: TxType.credit,
    reference: ref,
    date: date,
    confidence: received && date != null ? Confidence.high : Confidence.low,
    rawText: text,
    bank: 'telebirr',
    counterparty: _clean(m.group(3)!),
  );
}

// ── telebirr app "Transfer To Bank" receipt (green Successful screen) ───────
//
// What OCR reads, labels first and values after (column layout):
// "-5,515.00 (ETB) Successful Transaction Number: Transaction Time:
//  Transaction Type: Transaction To: Bank Account Numb... Bank Name:
//  DIH7T421XV 2026/09/17 16:37:36 Finished Transfer To Bank Mrs Sosina
//  Tilahun Getachew 1000563647737 Commercial Bank of Ethiopia QR Code"
// so every value is found by its own shape, never by the label before it.

final _telebirrAppMarkerRe = RegExp(
  r'Transaction Number.*Transaction Time',
  caseSensitive: false,
);
final _telebirrAppTimeRe = RegExp(
  r'\b(\d{4}/\d{2}/\d{2}\s+\d{1,2}:\d{2}(?::\d{2})?)\b',
);
final _telebirrAppAmountRe = RegExp(r'[-−–]?\s*([\d,]+[.,]\d{2})\s*\(?\s*ETB');
ParsedCbeMessage? _telebirrAppReceipt(String text, String? suffix) {
  if (!_telebirrAppMarkerRe.hasMatch(text)) return null;
  final time = _telebirrAppTimeRe.firstMatch(text);
  final amount = _telebirrAppAmountRe.firstMatch(text);
  if (time == null || amount == null) return null;
  final cents = _cents(amount.group(1)!);
  if (cents == null) return null;
  final ref = _tokenTenRe.firstMatch(text)?.group(0);
  if (ref == null) return null;
  final date = parseReceiptDate(time.group(1)!);
  return ParsedCbeMessage(
    amountCents: cents,
    type: TxType.credit,
    reference: ref,
    date: date,
    // Money arrived at a CBE account: certain. Any other receiving bank
    // isn't hers, so she looks at it.
    confidence: _mentionsCbe(text) && date != null
        ? Confidence.high
        : Confidence.low,
    rawText: text,
    bank: 'telebirr',
    // The receipt names the receiver (her), never the payer.
    counterparty: null,
  );
}

// ── Awash Bank app receipt ("Transaction Successful") ───────────────────────
//
// OCR, column layout: "AwashBank Transaction Time Transaction Type Amount
// Charge VAT Transaction Successful EDRRF Sender Name Sender Account
// Beneficiary name Beneficiary Account ciary Bank Reason 2026-09-17 03:28:03
// PM IPS Bank Transfer 4500 ETB 27.00 ETB 4.05 ETB 1.35 ETB ESRAEL TOLOSA
// TOLA 01347******100 MRS SOSINA TILAHUN GETACHEW 1000563647737 Commercial E
// Transfer". The values keep their order: the FIRST "N ETB" is the amount and
// the next three are charge, VAT and EDRRF; the sender's name is the caps run
// right after the last fee, before an account number. The "PM" can drift a
// line away from its time.

final _awashMarkerRe = RegExp(r'Awash\s*Bank', caseSensitive: false);
final _awashAmountRe = RegExp(r'\b([\d,]+(?:[.,]\d{1,2})?)\s*ETB\b');
final _awashTimeRe = RegExp(
  r'\b(\d{4}-\d{2}-\d{2}\s+\d{1,2}:\d{2}(?::\d{2})?)\b(.{0,40}?)\b([AP]M)\b',
  caseSensitive: false,
);
final _awashTimeNoMeridiemRe = RegExp(
  r'\b(\d{4}-\d{2}-\d{2}\s+\d{1,2}:\d{2}(?::\d{2})?)\b',
);
// The sender is the first ALL-CAPS name after the amounts, in either layout
// ("… 1.35 ETB ESRAEL TOLOSA TOLA 01347…" or "… Sender Name ESRAEL TOLOSA
// TOLA Sender Account …"); the Title Case labels never match.
final _awashSenderRe = RegExp(
  '\\d\\s*ETB\\b.*?\\b($_notNameWord[A-Z]{3,}(?:\\s+$_notNameWord[A-Z]{2,}){1,4})\\b',
);

ParsedCbeMessage? _awashReceipt(String text, String? suffix) {
  if (!_awashMarkerRe.hasMatch(text)) return null;
  final amount = _awashAmountRe.firstMatch(text);
  if (amount == null) return null;
  final cents = _cents(amount.group(1)!);
  if (cents == null) return null;

  DateTime? date;
  if (_awashTimeRe.firstMatch(text) case final m?) {
    date = parseReceiptDate('${m.group(1)} ${m.group(3)}');
  } else if (_awashTimeNoMeridiemRe.firstMatch(text) case final m?) {
    date = parseReceiptDate(m.group(1)!);
  }
  // Awash prints no reference; derive one so a re-upload is a duplicate.
  final reference = date == null
      ? null
      : deriveReceiptReference(bank: 'AWASH', date: date, cents: cents);
  // The stamp usually covers the beneficiary-bank line ("Commercial E"),
  // and every Awash receipt she gets is a customer paying her CBE account.
  return ParsedCbeMessage(
    amountCents: cents,
    type: TxType.credit,
    reference: reference,
    date: date,
    confidence: date != null ? Confidence.high : Confidence.low,
    rawText: text,
    bank: 'Awash Bank',
    counterparty: _awashSenderRe.firstMatch(text)?.group(1).let(_clean),
  );
}

// ── Bank of Abyssinia app receipt ("Acknowledgement / Successful") ──────────
//
// OCR, column layout: "Source Account Source Account Name Amount Transaction
// Type Receiver Account Receiver Name Acknowledgement Transaction Date Bank
// Name Transaction Reference Note Successful Screenshot BAMLAKU AREGA BALDA
// 1****9702 Other Bank Transfer 1000563647737 Scan the QR to Verify Mrs
// Sosina Tilahun Getachew ETB 302.16 16/09/2026, 11:11:34 Back To Home New
// Transfer Commercial Bank of Ethiopia FT26259w1QPT Share". Values by shape.

final _boaMarkerRe = RegExp(
  r'Source Account.*Transaction Reference',
  caseSensitive: false,
);
final _boaAmountRe = RegExp(r'\bETB\s*([\d,]+(?:[.,]\d{1,2})?)\b');
final _boaRefRe = RegExp(r'\b(FT[A-Za-z0-9]{10})\b');
final _boaDateRe = RegExp(
  r'\b(\d{1,2}/\d{1,2}/\d{4},?\s*\d{1,2}:\d{2}(?::\d{2})?)\b',
);

ParsedCbeMessage? _boaReceipt(String text, String? suffix) {
  if (!_boaMarkerRe.hasMatch(text)) return null;
  final amount = _boaAmountRe.firstMatch(text);
  final ref = _boaRefRe.firstMatch(text);
  if (amount == null || ref == null) return null;
  final cents = _cents(amount.group(1)!);
  if (cents == null) return null;
  final date = _boaDateRe.firstMatch(text)?.group(1).let(parseReceiptDate);
  return ParsedCbeMessage(
    amountCents: cents,
    type: TxType.credit,
    reference: ref.group(1)!.toUpperCase(),
    date: date,
    confidence: date != null && _mentionsCbe(text)
        ? Confidence.high
        : Confidence.low,
    rawText: text,
    bank: 'Bank of Abyssinia',
    counterparty: _capsNameRe.firstMatch(text)?.group(1).let(_clean),
  );
}

// ── Dashen Bank app receipt ─────────────────────────────────────────────────
//
// "Transaction Reference: 641OBTS2518100WH Transaction Date: Sep 15, 2026,
//  3:38:00 pm Transaction Amount: ETB 1,600.00 Receiver Name: Sosina Tilahun
//  Receiver Account Number: 1000563647737"

final _dashenRefRe = RegExp(
  r'Transaction Reference\s*:?\s*(\d{3}[A-Z]{4}\d{6,10}[A-Z]{2})\b',
  caseSensitive: false,
);
final _dashenAmountRe = RegExp(
  r'Transaction Amount\s*:?\s*ETB\s*([\d,]+(?:\.\d{1,2})?)',
  caseSensitive: false,
);
final _dashenDateRe = RegExp(
  r'Transaction Date\s*:?\s*([A-Za-z]{3,9}\s+\d{1,2},\s*\d{4},?\s*\d{1,2}:\d{2}(?::\d{2})?\s*[apAP][mM])',
);

ParsedCbeMessage? _dashenReceipt(String text, String? suffix) {
  final ref = _dashenRefRe.firstMatch(text);
  final amount = _dashenAmountRe.firstMatch(text);
  if (ref == null || amount == null) return null;
  final cents = _cents(amount.group(1)!);
  if (cents == null) return null;
  final date = _dashenDateRe.firstMatch(text)?.group(1).let(parseReceiptDate);
  return ParsedCbeMessage(
    amountCents: cents,
    type: TxType.credit,
    reference: ref.group(1)!.toUpperCase(),
    date: date,
    confidence: date != null ? Confidence.high : Confidence.low,
    rawText: text,
    bank: 'Dashen Bank',
    // Dashen's receipt names the receiver (her), not the payer.
    counterparty: null,
  );
}

// ── "your transfer of N ETB was successful" SMS (Awash, Dashen, Zemen) ──────
//
// "Dear Customer, your transfer of 500 ETB was successful. View receipt:
//  https://awashpay.awashbank.com:8225/-E4092F0CEBDB-205TGG"
// "… https://receipt.dashensuperapp.com/receipt/641OBTS2518100WH"
// "… https://share.zemenbank.com/rt/ZM987654321/pdf"

final _transferSmsRe = RegExp(
  r'your transfer of\s+([\d,]+(?:\.\d{1,2})?)\s*ETB\s+was successful',
  caseSensitive: false,
);
final _awashLinkRe = RegExp(
  r'awashpay\.awashbank\.com[:\d]*/-([A-Za-z0-9-]+)',
  caseSensitive: false,
);
final _dashenLinkRe = RegExp(
  r'dashensuperapp\.com/receipt/([A-Za-z0-9]+)',
  caseSensitive: false,
);
final _zemenLinkRe = RegExp(
  r'zemenbank\.com/rt/([A-Za-z0-9]+)',
  caseSensitive: false,
);

ParsedCbeMessage? _transferSuccessSms(String text, String? suffix) {
  final m = _transferSmsRe.firstMatch(text);
  if (m == null) return null;
  final cents = _cents(m.group(1)!);
  if (cents == null) return null;
  String? bank;
  String? reference;
  if (_awashLinkRe.firstMatch(text) case final a?) {
    bank = 'Awash Bank';
    reference = a.group(1)!.toUpperCase();
  } else if (_dashenLinkRe.firstMatch(text) case final d?) {
    bank = 'Dashen Bank';
    reference = d.group(1)!.toUpperCase();
  } else if (_zemenLinkRe.firstMatch(text) case final z?) {
    bank = 'Zemen Bank';
    reference = z.group(1)!.toUpperCase();
  }
  return ParsedCbeMessage(
    amountCents: cents,
    type: TxType.credit,
    reference: reference,
    date: null, // these SMS carry no timestamp; the batch day supplies it
    // A customer's own SMS says nothing about where the money went — she
    // confirms the row. The receipt link is still the duplicate guard.
    confidence: Confidence.low,
    rawText: text,
    bank: bank,
    counterparty: null,
  );
}

// ── Shared: dates and derived references ────────────────────────────────────

const Map<String, int> _months = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

final _dmyRe = RegExp(
  r'^(\d{1,2})/(\d{1,2})/(\d{4})(?:,?\s*(?:at\s+)?(\d{1,2}):(\d{2})(?::(\d{2}))?)?$',
);
final _ymdSlashRe = RegExp(
  r'^(\d{4})[/-](\d{2})[/-](\d{2})(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AP]M)?)?$',
  caseSensitive: false,
);
final _monthNameRe = RegExp(
  r'^([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2}),?\s*(\d{4}),?\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AP]M)?$',
  caseSensitive: false,
);

/// Every date shape seen on the receipts above, or null:
///  * `16/09/2026, 11:11:34` · `14/07/2026 at 10:42` · `16/09/2026`
///  * `2026/09/17 16:37:36` · `2026-09-17 03:28:03 PM`
///  * `Sep 15, 2026 03:38 PM` · `Sep 15, 2026, 3:38:00 pm`
DateTime? parseReceiptDate(String raw) {
  final s = _clean(raw);

  int hour24(int hour, String? meridiem) {
    if (meridiem == null) return hour;
    final pm = meridiem.toUpperCase() == 'PM';
    if (pm && hour != 12) return hour + 12;
    if (!pm && hour == 12) return 0;
    return hour;
  }

  DateTime? build(int y, int mo, int d, int h, int mi, int sec) {
    if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59) return null;
    return DateTime(y, mo, d, h, mi, sec);
  }

  if (_dmyRe.firstMatch(s) case final m?) {
    return build(
      int.parse(m.group(3)!),
      int.parse(m.group(2)!),
      int.parse(m.group(1)!),
      int.parse(m.group(4) ?? '0'),
      int.parse(m.group(5) ?? '0'),
      int.parse(m.group(6) ?? '0'),
    );
  }
  if (_ymdSlashRe.firstMatch(s) case final m?) {
    return build(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      hour24(int.parse(m.group(4) ?? '0'), m.group(7)),
      int.parse(m.group(5) ?? '0'),
      int.parse(m.group(6) ?? '0'),
    );
  }
  if (_monthNameRe.firstMatch(s) case final m?) {
    final month = _months[m.group(1)!.toLowerCase()];
    if (month == null) return null;
    return build(
      int.parse(m.group(3)!),
      month,
      int.parse(m.group(2)!),
      hour24(int.parse(m.group(4)!), m.group(7)),
      int.parse(m.group(5)!),
      int.parse(m.group(6) ?? '0'),
    );
  }
  return null;
}

/// A stable stand-in reference for receipts that print none:
/// `AWASH-20260917152803-450000`. The same rule the AI fallback uses, so a
/// receipt read by either path dedupes against the other.
String deriveReceiptReference({
  required String bank,
  required DateTime date,
  required int cents,
}) {
  final tag = bank
      .toUpperCase()
      .replaceAll(RegExp(r'[^A-Z0-9]'), '')
      .replaceAll('BANK', '');
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp =
      '${date.year}${two(date.month)}${two(date.day)}'
      '${two(date.hour)}${two(date.minute)}${two(date.second)}';
  return '${tag.isEmpty ? 'BANK' : tag}-$stamp-$cents';
}

extension<T> on T? {
  R? let<R>(R? Function(T) f) {
    final v = this;
    return v == null ? null : f(v);
  }
}

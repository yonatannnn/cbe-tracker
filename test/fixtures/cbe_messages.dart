/// Anonymized CBE message fixtures for parser unit tests (§4).
///
/// The `raw` strings are the parser inputs; the other fields are the expected
/// parse results. Raw token shapes (amounts, keywords, FT refs) are exact —
/// do not tweak them.
library;

import 'package:cbe_tracker/core/parser/cbe_parser.dart';

/// One parser test case: a raw input plus either its expected parse or a flag
/// that parsing must throw.
class CbeFixture {
  CbeFixture.value({
    required this.name,
    required this.raw,
    required this.type,
    required this.amountCents,
    required this.reference,
    required this.date,
    required this.confidence,
  }) : expectThrows = false;

  CbeFixture.throws({required this.name, required this.raw})
    : expectThrows = true,
      type = null,
      amountCents = null,
      reference = null,
      date = null,
      confidence = null;

  final String name;
  final String raw;
  final bool expectThrows;
  final TxType? type;
  final int? amountCents;
  final String? reference;
  final DateTime? date;
  final Confidence? confidence;
}

// A single reusable FT reference token. The receipt URL appends the account
// suffix (…12341234); the true reference is the first 12 chars, FT + 10.
const _refUrl = 'https://apps.cbe.com.et:100/?id=FT26195XKQ8T12341234';
const _ref = 'FT26195XKQ8T';

// ── Clean cases ────────────────────────────────────────────────────────────

/// 1. Credit, comma amount, full well-formed message.
final fixtureCreditClean = CbeFixture.value(
  name: '1: credit, comma thousands, full message',
  raw:
      'Dear YONATAN your Account 1*****1234 has been Credited with ETB '
      '5,000.00 from ABEBE KEBEDE on 14/07/2026 at 10:42. Your Current '
      'Balance is ETB 145,200.00. Thank you for Banking with CBE! $_refUrl',
  type: TxType.credit,
  amountCents: 500000,
  reference: _ref,
  date: DateTime(2026, 7, 14, 10, 42),
  confidence: Confidence.high,
);

/// 2. Same shape but debited.
final fixtureDebitClean = CbeFixture.value(
  name: '2: debit, comma thousands',
  raw:
      'Dear YONATAN your Account 1*****1234 has been Debited with ETB '
      '12,300.00 to XYZ TRADING on 14/07/2026 at 11:05. Your Current '
      'Balance is ETB 132,900.00. Thank you for Banking with CBE! $_refUrl',
  type: TxType.debit,
  amountCents: 1230000,
  reference: _ref,
  date: DateTime(2026, 7, 14, 11, 05),
  confidence: Confidence.high,
);

/// 3. Amount without a thousands separator.
final fixtureNoSeparator = CbeFixture.value(
  name: '3: credit, no thousands separator',
  raw:
      'Dear YONATAN your Account 1*****1234 has been Credited with ETB '
      '850.00 from HANA GIRMA on 14/07/2026 at 08:20. Your Current Balance '
      'is ETB 6,050.00. Thank you for Banking with CBE! $_refUrl',
  type: TxType.credit,
  amountCents: 85000,
  reference: _ref,
  date: DateTime(2026, 7, 14, 08, 20),
  confidence: Confidence.high,
);

/// 4. Large amount (also two amounts: transaction vs balance).
final fixtureLargeAmount = CbeFixture.value(
  name: '4: credit, large amount',
  raw:
      'Dear YONATAN your Account 1*****1234 has been Credited with ETB '
      '1,250,000.00 from MEGA CONSTRUCTION on 14/07/2026 at 14:00. Your '
      'Current Balance is ETB 1,395,200.00. Thank you for Banking with CBE! '
      '$_refUrl',
  type: TxType.credit,
  amountCents: 125000000,
  reference: _ref,
  date: DateTime(2026, 7, 14, 14, 00),
  confidence: Confidence.high,
);

/// 5. Lowercase "credited" mid-sentence (not "has been Credited").
final fixtureLowercaseKeyword = CbeFixture.value(
  name: '5: lowercase credited mid-sentence',
  raw:
      'Transaction alert: your account was credited with ETB 2,500.00 from '
      'DANIEL BEKELE on 14/07/2026 at 16:45. Current Balance ETB 8,500.00. '
      '$_refUrl',
  type: TxType.credit,
  amountCents: 250000,
  reference: _ref,
  date: DateTime(2026, 7, 14, 16, 45),
  confidence: Confidence.high,
);

// ── Edge cases ─────────────────────────────────────────────────────────────

/// 6. Reference URL truncated by OCR → parses, but reference null + LOW.
final fixtureTruncatedRef = CbeFixture.value(
  name: '6: truncated FT ref → reference null, LOW',
  raw:
      'Dear YONATAN your Account 1*****1234 has been Credited with ETB '
      '3,200.00 from SARA TESFAYE on 14/07/2026 at 12:30. Your Current '
      'Balance is ETB 11,700.00. Thank you for Banking with CBE! '
      'https://apps.cbe.com.et:100/?id=FT2619',
  type: TxType.credit,
  amountCents: 320000,
  reference: null,
  date: DateTime(2026, 7, 14, 12, 30),
  confidence: Confidence.low,
);

/// 7. Two ETB amounts: expected is the one adjacent to the keyword, never the
///    Current Balance.
final fixtureTwoAmounts = CbeFixture.value(
  name: '7: two amounts → adjacent one, not Current Balance',
  raw:
      'Dear YONATAN your Account 1*****1234 has been Credited with ETB '
      '7,500.00 from ALMAZ TESFA on 14/07/2026 at 09:15. Your Current '
      'Balance is ETB 145,200.00. Thank you for Banking with CBE! $_refUrl',
  type: TxType.credit,
  amountCents: 750000,
  reference: _ref,
  date: DateTime(2026, 7, 14, 09, 15),
  confidence: Confidence.high,
);

/// 8. OCR noise: a line break splits "Credited" mid-word.
final fixtureLineBreakKeyword = CbeFixture.value(
  name: '8: line break mid-keyword → normalized, still parses',
  raw:
      'Dear YONATAN your Account 1*****1234 has been Cred\nited with ETB '
      '5,000.00 from ABEBE KEBEDE on 14/07/2026 at 10:42. Your Current '
      'Balance is ETB 145,200.00. $_refUrl',
  type: TxType.credit,
  amountCents: 500000,
  reference: _ref,
  date: DateTime(2026, 7, 14, 10, 42),
  confidence: Confidence.high,
);

/// 9. Date line unreadable → parses, but date null + LOW.
final fixtureUnreadableDate = CbeFixture.value(
  name: '9: unreadable date → date null, LOW',
  raw:
      'Dear YONATAN your Account 1*****1234 has been Credited with ETB '
      '4,750.00 from GETNET ALEMU on ??/??/2026 at ??:??. Your Current '
      'Balance is ETB 20,000.00. Thank you for Banking with CBE! $_refUrl',
  type: TxType.credit,
  amountCents: 475000,
  reference: _ref,
  date: null,
  confidence: Confidence.low,
);

/// 10. No amount at all → throws.
final fixtureNoAmount = CbeFixture.throws(
  name: '10: no amount → ParseException',
  raw:
      'Dear YONATAN your Account 1*****1234 has been Credited on 14/07/2026 '
      'at 10:42. Thank you for Banking with CBE!',
);

/// 11. Amount present but no credited/debited keyword → throws.
final fixtureNoKeyword = CbeFixture.throws(
  name: '11: amount but no credit/debit keyword → ParseException',
  raw:
      'Dear YONATAN your Account 1*****1234 shows a transaction of ETB '
      '5,000.00 on 14/07/2026 at 10:42. Your Current Balance is ETB '
      '145,200.00. Thank you for Banking with CBE!',
);

/// 12. Empty string → throws.
final fixtureEmpty = CbeFixture.throws(name: '12: empty string', raw: '');

// ── Real CBE app receipts ──────────────────────────────────────────────────
//
// Transcribed from an ACTUAL screenshot read by ML Kit on-device (names and
// account digits anonymized). This is the "Transaction Summary" receipt the
// CBE mobile app shows after a transfer — a completely different shape from
// the SMS format §4 describes, and the format the user actually screenshots.
//
// Landmines this fixture pins:
//  * the amount comes BEFORE the keyword ("ETB 1.00 has been debited");
//  * "Total Amount Debited: ETB1.61" contains the keyword "Debited" and sits
//    CLOSER to 1.61 than the real amount does to its keyword — the parser must
//    still choose 1.00;
//  * the fee lines add three more decoy amounts;
//  * the date reads "on Jul 15, 2026 11:45 AM", not "on 15/07/2026 at 11:45";
//  * "ETB-8402" is an account id, not an amount.

/// 13. Real MB Transfer debit receipt.
final fixtureRealReceiptDebit = CbeFixture.value(
  name: '13: real app receipt, debit with fees',
  raw:
      'Thank you Success Transaction Completed Successfully! '
      'Transaction Summary '
      'ETB 1.00 has been debited from ABEBE KEBEDE TESFAYE ETB-8402 for '
      'ALMAZ TESFA GIRMA ETB-3487 on Jul 15, 2026 11:45 AM with transaction '
      'ID: FT26196FZHT2. Reason: MB Transfer '
      'Total Amount Debited: ETB1.61 with Service Charge of ETB0.50, VAT '
      '(15%) of ETB0.08 and Disaster Recovery (5%) of ETB0.03. '
      'Commercial Bank of Ethiopia The bank you can always rely on!',
  type: TxType.debit,
  // The transfer itself — NOT the 1.61 fee-inclusive total.
  amountCents: 100,
  reference: 'FT26196FZHT2',
  date: DateTime(2026, 7, 15, 11, 45),
  confidence: Confidence.high,
);

// ── Real CBE SMS ───────────────────────────────────────────────────────────
//
// Transcribed from an actual 491-message CBE inbox (names and account digits
// anonymized). §4 describes only the legacy "has been credited with ETB x …
// FT…" wording, which turned out to be a MINORITY of live traffic — the
// parser read just 105 of 491 before these were added.
//
// Shared traits that broke the original parser:
//  * the live wording is received / transferred / "a debit transaction of",
//    never credited/debited;
//  * amounts appear as "ETB2.00", "ETB 2000.0" and "ETB 4,000.00";
//  * fee lines and a "with total of" summary give 4+ decoy amounts;
//  * there is NO date and usually NO FT reference — so these parse LOW by
//    design, which is correct: for SMS we take the time from the message
//    metadata, not the body.

/// 14. Live credit: "You have received".
final fixtureSmsReceived = CbeFixture.value(
  name: '14: real SMS, credit via "You have received"',
  raw:
      'ABEBE KEBEDE TESFAYE You have received ETB 4,000.00 from account '
      '1********2 (ALMAZ TESFA GIRMA) to your account 1********3. Your '
      'current balance is ETB31,897.92. Thanks for Banking with CBE. '
      'https://mbreciept.cbe.com.et/v2-hfHCxzX0x3dSPNjfeMcj',
  type: TxType.credit,
  amountCents: 400000,
  // No FT number in modern messages — only an opaque receipt URL.
  reference: null,
  date: null,
  confidence: Confidence.low,
);

/// 15. Live debit: "A debit transaction of", one-decimal amount, fee lines.
final fixtureSmsDebitTransaction = CbeFixture.value(
  name: '15: real SMS, debit via "A debit transaction of" (1-decimal amount)',
  raw:
      'ABEBE KEBEDE TESFAYE A debit transaction of ETB 2000.0. has occurred '
      'on your account 1********2. Service charge of ETB 10.00 and VAT(15%) '
      'of ETB1.50 and Disaster Recovery(5%) of 0.50 with total of ETB2012.00 '
      '.Your current balance is ETB22,481.12. Thanks for Banking with CBE. '
      'https://mbreciept.cbe.com.et/v2-hfHCxzXrkU12QGxusq3k',
  type: TxType.debit,
  // The transaction, not the ETB2012.00 fee-inclusive total.
  amountCents: 200000,
  reference: null,
  date: null,
  confidence: Confidence.low,
);

/// 16. Live debit: "You have successfully transferred", no space after ETB.
final fixtureSmsTransferred = CbeFixture.value(
  name: '16: real SMS, debit via "successfully transferred"',
  raw:
      'ABEBE KEBEDE TESFAYE You have successfully transferred ETB2.00 from '
      'account 1********2 to account 1********3 (ALMAZ TESFA GIRMA). Service '
      'charge of ETB 0.50 and VAT(15%) of ETB0.08 and Disaster Recovery(5%) '
      'of 0.03 with total of ETB2.61 .Your current balance is ETB22,321.29. '
      'Thanks for Banking with CBE. '
      'https://mbreciept.cbe.com.et/v2-hfHCxzXQNBsuCXntXW0y',
  type: TxType.debit,
  // Not the 2.61 total, not the 0.50 charge, not the 22,321.29 balance.
  amountCents: 200,
  reference: null,
  date: null,
  confidence: Confidence.low,
);

/// 17. Amharic fraud-warning notice — CBE sends these; they are NOT
///     transactions and must be refused, not guessed at.
final fixtureSmsAmharicNotice = CbeFixture.throws(
  name: '17: real SMS, Amharic security notice → ParseException',
  raw:
      'ለውድ ደንበኛችን፡ የጥንቃቄ መልዕክት አለን። ከሞባይል ባንኪንግ አገልግሎት ጋር በተያያዘ እርስዎ በአካል ወደ '
      'ባንካችን ቅርንጫፎች ሳይመጡ በስልክ ተደውሎ የሚሰጥ ምንም አይነት አገልግሎትም ሆነ የአሠራር ሂደት የሌለን '
      'መሆኑን እያሳወቅን፤ የይለፍ ቃልዎን ለሌላ ሶስተኛ ወገን ተጋላጭ ባለማድረግ በጥንቃቄ እንዲገለገሉ እናሳውቃለን፡፡',
);

/// 18. CBEBirr PIN-expiry notice — also not a transaction.
final fixtureSmsPinNotice = CbeFixture.throws(
  name: '18: real SMS, CBEBirr PIN notice → ParseException',
  raw:
      'ABEBE KEBEDE TESFAYE, your PIN will be expired in 0 days, please '
      'change it in time. Thank you!',
);

/// Fixtures 1–5.
final cleanFixtures = <CbeFixture>[
  fixtureCreditClean,
  fixtureDebitClean,
  fixtureNoSeparator,
  fixtureLargeAmount,
  fixtureLowercaseKeyword,
];

/// Fixtures 6–12.
final edgeFixtures = <CbeFixture>[
  fixtureTruncatedRef,
  fixtureTwoAmounts,
  fixtureLineBreakKeyword,
  fixtureUnreadableDate,
  fixtureNoAmount,
  fixtureNoKeyword,
  fixtureEmpty,
];

/// Fixtures transcribed from real screenshots and a real SMS inbox.
final realFixtures = <CbeFixture>[
  fixtureRealReceiptDebit,
  fixtureSmsReceived,
  fixtureSmsDebitTransaction,
  fixtureSmsTransferred,
  fixtureSmsAmharicNotice,
  fixtureSmsPinNotice,
];

/// All fixtures, in numbered order.
final allFixtures = <CbeFixture>[
  ...cleanFixtures,
  ...edgeFixtures,
  ...realFixtures,
];

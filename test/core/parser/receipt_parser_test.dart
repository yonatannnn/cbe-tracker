// Receipt templates beyond the CBE SMS. Every raw text below is what ML Kit
// reads off a real receipt photographed in September 2026 (names kept as on
// the receipts, all of which the owner shared), or a real SMS format.

import 'package:cbe_tracker/core/parser/cbe_parser.dart';
import 'package:cbe_tracker/core/parser/receipt_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const owner = '7737'; // her CBE account ends with these digits

  group('CBE app transfer receipt (purple "Thank you" screen)', () {
    const raw =
        'Thank you Success Transaction Completed Successfully! Transaction '
        'Summary ETB 1,000.00 has been debited from Getu Tolosa Tola ETB-4351 '
        'for Sosina Tilahun Getachew ETB-7737 on Sep 15, 2026 03:38 PM with '
        'transaction ID: FT26258GYG1C. Reason: MB Transfer Total Amount '
        'Debited: ETB1000.61 with Service Charge of ETB0.50, VAT (15%) of '
        'ETB0.08 and Disaster Recovery (5%) of ETB0.03. '
        'Commercial Bank of Ethiopia';

    test('a customer paying her → credit, HIGH, fees excluded', () {
      final p = parseReceiptText(raw, ownerAccountSuffix: owner);
      expect(p.amountCents, 100000, reason: 'not the 1000.61 total');
      expect(p.type, TxType.credit);
      expect(p.reference, 'FT26258GYG1C');
      expect(p.date, DateTime(2026, 9, 15, 15, 38));
      expect(p.confidence, Confidence.high);
      expect(p.bank, 'CBE');
      expect(p.counterparty, 'Getu Tolosa Tola');
    });

    test('her own outgoing transfer → debit, HIGH', () {
      final p = parseReceiptText(raw, ownerAccountSuffix: '4351');
      expect(p.type, TxType.debit);
      expect(p.confidence, Confidence.high);
      expect(p.counterparty, 'Sosina Tilahun Getachew');
    });

    test('no account suffix set → credit, LOW (she checks)', () {
      final p = parseReceiptText(raw);
      expect(p.type, TxType.credit);
      expect(p.confidence, Confidence.low);
      expect(p.amountCents, 100000);
    });

    test('a suffix matching neither side → LOW', () {
      final p = parseReceiptText(raw, ownerAccountSuffix: '0000');
      expect(p.confidence, Confidence.low);
    });

    test('the suffix may be typed with the ETB- prefix', () {
      final p = parseReceiptText(raw, ownerAccountSuffix: 'ETB-7737');
      expect(p.type, TxType.credit);
      expect(p.confidence, Confidence.high);
    });
  });

  group('CBE USSD (*889#) confirmation', () {
    const raw =
        'Completed ETB300.61 transfer From Mastewal Molla Aynalem to Sosina '
        'Tilahun Getachew-7737. To kgj on 16/09/2026 FT26259194Y1 Service '
        'Charge #:Next';

    test('customer → her: credit with the FT reference and the day', () {
      final p = parseReceiptText(raw, ownerAccountSuffix: owner);
      expect(p.amountCents, 30061);
      expect(p.type, TxType.credit);
      expect(p.reference, 'FT26259194Y1');
      expect(p.date, DateTime(2026, 9, 16));
      expect(p.confidence, Confidence.high);
      expect(p.counterparty, 'Mastewal Molla Aynalem');
    });

    test('unknown suffix → LOW', () {
      expect(parseReceiptText(raw).confidence, Confidence.low);
    });
  });

  group('telebirr SMS', () {
    test('"You have received" → credit, HIGH, 10-char reference', () {
      const raw =
          'You have received ETB 50.00 from hayat rahmeto(2519****8938) '
          '100504 on 11/09/2026 21:59:18. Your transaction number is '
          'DIB6NHE3H2. Your current E-Money Account balance is ETB 105.50.';
      final p = parseReceiptText(raw);
      expect(p.amountCents, 5000, reason: 'not the 105.50 balance');
      expect(p.type, TxType.credit);
      expect(p.reference, 'DIB6NHE3H2');
      expect(p.date, DateTime(2026, 9, 11, 21, 59, 18));
      expect(p.confidence, Confidence.high);
      expect(p.bank, 'telebirr');
      expect(p.counterparty, 'hayat rahmeto');
    });

    test('"You have transferred" (a customer\'s SMS) → credit, LOW', () {
      const raw =
          'Dear Ephrem You have transferred ETB 600.00 to asefa aynalem on '
          '31/05/2026. Your transaction number is DEV6HKJX7K.';
      final p = parseReceiptText(raw);
      expect(p.amountCents, 60000);
      expect(p.type, TxType.credit);
      expect(p.reference, 'DEV6HKJX7K');
      expect(p.date, DateTime(2026, 5, 31));
      expect(p.confidence, Confidence.low);
      expect(p.counterparty, 'asefa aynalem');
    });
  });

  group('telebirr app "Transfer To Bank" receipt (green screen)', () {
    const raw =
        'Successful −5,515.00 (ETB) Transaction Number: DIH7T42IXV '
        'Transaction Time: 2026/09/17 16:37:36 Transaction Type: Transfer To '
        'Bank Transaction To: Mrs Sosina Tilahun Getachew Bank Account '
        'Numb...: 1000563647737 Bank Name: Commercial Bank of Ethiopia QR Code '
        'Finished';

    test('money to a CBE account → credit, HIGH, minus sign ignored', () {
      final p = parseReceiptText(raw);
      expect(p.amountCents, 551500);
      expect(p.type, TxType.credit);
      expect(p.reference, 'DIH7T42IXV');
      expect(p.date, DateTime(2026, 9, 17, 16, 37, 36));
      expect(p.confidence, Confidence.high);
      expect(p.bank, 'telebirr');
      expect(p.counterparty, 'Mrs Sosina Tilahun Getachew');
    });

    test('to some other bank → LOW', () {
      final p = parseReceiptText(
        raw.replaceFirst('Commercial Bank of Ethiopia', 'Awash Bank'),
      );
      expect(p.confidence, Confidence.low);
    });
  });

  group('Awash Bank IPS receipt', () {
    const raw =
        'AwashBank Transaction Successful Transaction Time 2026-09-17 '
        '03:28:03 PM Transaction Type IPS Bank Transfer Amount 4500 ETB '
        'Charge 27.00 ETB VAT 4.05 ETB EDRRF 1.35 ETB Sender Name ESRAEL '
        'TOLOSA TOLA Sender Account 01347******100 Beneficiary name MRS '
        'SOSINA TILAHUN GETACHEW Beneficiary Account 1000563647737 '
        'Beneficiary Bank Commercial B Reason Transfer';

    test('credit 4500, charges ignored, reference derived, 12h time', () {
      final p = parseReceiptText(raw);
      expect(p.amountCents, 450000);
      expect(p.type, TxType.credit);
      expect(p.date, DateTime(2026, 9, 17, 15, 28, 3));
      expect(p.reference, 'AWASH-20260917152803-450000');
      expect(p.confidence, Confidence.high);
      expect(p.bank, 'Awash Bank');
      expect(p.counterparty, 'ESRAEL TOLOSA TOLA');
    });

    test('the same rule as the AI path, so both dedupe together', () {
      expect(
        deriveReceiptReference(
          bank: 'Awash Bank',
          date: DateTime(2026, 9, 17, 15, 28, 3),
          cents: 450000,
        ),
        'AWASH-20260917152803-450000',
      );
    });
  });

  group('Bank of Abyssinia receipt (Acknowledgement)', () {
    const raw =
        'Acknowledgement Successful Source Account 1****9702 Source Account '
        'Name BAMLAKU AREGA BALDA Amount ETB 302.16 Transaction Type Other '
        'Bank Transfer Receiver Account 1000563647737 Receiver Name Mrs '
        'Sosina Tilahun Getachew Transaction Date 16/09/2026, 11:11:34 '
        'Transaction Reference FT26259W1QPT Bank Name Commercial Bank of '
        'Ethiopia Note Scan the QR to Verify';

    test('credit with FT reference and comma date', () {
      final p = parseReceiptText(raw);
      expect(p.amountCents, 30216);
      expect(p.type, TxType.credit);
      expect(p.reference, 'FT26259W1QPT');
      expect(p.date, DateTime(2026, 9, 16, 11, 11, 34));
      expect(p.confidence, Confidence.high);
      expect(p.bank, 'Bank of Abyssinia');
      expect(p.counterparty, 'BAMLAKU AREGA BALDA');
    });
  });

  group('Dashen Bank receipt', () {
    test('credit with the Dashen-shaped reference', () {
      const raw =
          'Transaction Reference: 641OBTS2518100WH Transaction Date: Sep 15, '
          '2026, 3:38:00 pm Transaction Amount: ETB 1,600.00 Receiver Name: '
          'Sosina Tilahun Receiver Account Number: 1000563647737';
      final p = parseReceiptText(raw);
      expect(p.amountCents, 160000);
      expect(p.type, TxType.credit);
      expect(p.reference, '641OBTS2518100WH');
      expect(p.date, DateTime(2026, 9, 15, 15, 38));
      expect(p.confidence, Confidence.high);
      expect(p.bank, 'Dashen Bank');
    });
  });

  group('"your transfer of N ETB was successful" SMS', () {
    test('Awash link → credit LOW, link token as reference', () {
      const raw =
          'Dear Customer, your transfer of 500 ETB was successful. View '
          'receipt: https://awashpay.awashbank.com:8225/-E4092F0CEBDB-205TGG';
      final p = parseReceiptText(raw);
      expect(p.amountCents, 50000);
      expect(p.type, TxType.credit);
      expect(p.reference, 'E4092F0CEBDB-205TGG');
      expect(p.date, isNull);
      expect(p.confidence, Confidence.low);
      expect(p.bank, 'Awash Bank');
    });

    test('Dashen and Zemen links', () {
      final dashen = parseReceiptText(
        'Dear Customer, your transfer of 1,600 ETB was successful. View '
        'receipt: https://receipt.dashensuperapp.com/receipt/641OBTS2518100WH',
      );
      expect(dashen.amountCents, 160000);
      expect(dashen.reference, '641OBTS2518100WH');
      expect(dashen.bank, 'Dashen Bank');

      final zemen = parseReceiptText(
        'Dear Customer, your transfer of 2,000 ETB was successful. View '
        'receipt: https://share.zemenbank.com/rt/ZM987654321/pdf',
      );
      expect(zemen.amountCents, 200000);
      expect(zemen.reference, 'ZM987654321');
      expect(zemen.bank, 'Zemen Bank');
    });
  });

  group('what ML Kit actually reads off a photographed screen', () {
    // Column layouts come out labels-first, values-after; a "PM" drifts a
    // line; a dot becomes a comma; a stamp eats the bank name.
    test('Awash, values after labels, PM on its own line', () {
      const ocr =
          'AwashBank Transaction Time Transăction Type Amount Charge VAT '
          'Transaction Successful TEDRRE Sender Name Sender Account '
          'Beneficiary name Beneficiary Account ciary Bank Reason 2026-09-17 '
          '03:28:03 PM IPS Bank Transfar 4500 ETB 27.00 ETB 4.05 ETB 1.35 ETB '
          'ESRAEL TOLOSA TOLA 01347******100 MRS SOSINA TILAHUN GETACHEW '
          '1000563647737 Commercial E Transfer 9:12 AM';
      final p = parseReceiptText(ocr);
      expect(p.amountCents, 450000);
      expect(p.date, DateTime(2026, 9, 17, 15, 28, 3));
      expect(p.reference, 'AWASH-20260917152803-450000');
      expect(p.confidence, Confidence.high);
      expect(p.counterparty, 'ESRAEL TOLOSA TOLA');
    });

    test('Awash, PM displaced past the transaction type', () {
      const ocr =
          'AwashBank Transaction Time Transăction Type Amount Charge VAT '
          'Transaction Successful EDRRF Sender Name Sender Account '
          'Beneficiary name Beneficiary Account ciary Bank eason 2026-09-17 '
          '03:28:03 IPS Bank Transfar PM 4500 ETB 27.00 ETB 4.05 ETB 1.35 ETB '
          'ESRAEL TOLOSA TOLA 01347***** 100 MRS SOSINA TILAHUN GETACHEW '
          '1000563647737 Commercial E Transfer';
      final p = parseReceiptText(ocr);
      expect(p.amountCents, 450000);
      expect(p.date, DateTime(2026, 9, 17, 15, 28, 3));
      expect(p.confidence, Confidence.high);
    });

    test('telebirr app, values after labels', () {
      const ocr =
          '-5,515.00 (ETB) Successful Transaction Number: Transaction Time: '
          'Transaction Type: Transaction To: Bank Account Numb... Bank Name: '
          'DIH7T421XV 2026/09/17 16:37:36 Finished Transfer To Bank Mrs Sosina '
          'Tilahun Getachew 1000563647737 Commercial Bank of Ethiopia aN QR Code';
      final p = parseReceiptText(ocr);
      expect(p.amountCents, 551500);
      expect(p.type, TxType.credit);
      expect(p.reference, 'DIH7T421XV');
      expect(p.date, DateTime(2026, 9, 17, 16, 37, 36));
      expect(p.confidence, Confidence.high);
      expect(p.counterparty, 'Mrs Sosina Tilahun Getachew');
    });

    test('Bank of Abyssinia, values after labels, lower-case OCR in the ref', () {
      const ocr =
          '11:11 Source Account Source Account Name Amount Transaction Type '
          'Receiver Account Receiver Name Acknowledgement Transaction Date Bank '
          'Name Transaction Reference Note Successful Screenshot BAMLAKU AREGA '
          'BALDA 5G92 1****g702 Other Bank Transfer 1000563647737 Scan the QR '
          'to Verify Mrs Sosina Tilahun Getachew ETB 302.16 16/09/2026, '
          '11:11:34 Back To Home New Transfer Commercial Bank of Ethiopia '
          'FT26259w1QPT Share ALT VD zeGeLLaazodaaAN';
      final p = parseReceiptText(ocr);
      expect(p.amountCents, 30216);
      expect(p.reference, 'FT26259W1QPT');
      expect(p.date, DateTime(2026, 9, 16, 11, 11, 34));
      expect(p.confidence, Confidence.high);
      expect(p.bank, 'Bank of Abyssinia');
      expect(p.counterparty, 'BAMLAKU AREGA BALDA');
    });

    test('USSD text with the decimal dot read as a comma', () {
      const ocr =
          '1 Completed ETB300,61 transfer From Mastewal Molla Aynalem to '
          'Sosina Tilahun Getachew-7737. To kgý on 16/09/2026 FT26259194Y1 '
          'Service Charge #Next 1#1 GHL W Cancel JKL 23 4 5 678 9 9 Send';
      final p = parseReceiptText(ocr, ownerAccountSuffix: owner);
      expect(p.amountCents, 30061, reason: '300,61 is 300.61, not 30,061');
      expect(p.type, TxType.credit);
      expect(p.reference, 'FT26259194Y1');
      expect(p.confidence, Confidence.high);
    });

    test('CBE app receipt with OCR zeros read as the letter O in fee lines', () {
      const ocr =
          'Thank you Success Transaction Completed Successfully! Transaction '
          'Summary ETB 1,000.00 has been debited from Getu Tolosa Tola ETB-4351 '
          'for Sosina Tilahun Getachew ETB-7737 on Sep 15, 2026 03:38 PM with '
          'transaction ID: FT26258GYG1C. Reason: MB Transfer Total Amount '
          'Debited: ETB1000.61 with Service Charge of ETBO.50, VAT (15%) of '
          'ETBO.08 and Disaster Recovery (5%) of ETBO.03. Commercial Bank of '
          'Ethiopia';
      final p = parseReceiptText(ocr, ownerAccountSuffix: owner);
      expect(p.amountCents, 100000);
      expect(p.type, TxType.credit);
      expect(p.confidence, Confidence.high);
    });
  });

  group('falls back to the CBE SMS parser', () {
    test('her own CBE credit SMS still parses exactly as before', () {
      const raw =
          'Dear YONATAN your Account 1*****1234 has been Credited with ETB '
          '5,000.00 from ABEBE KEBEDE on 14/07/2026 at 10:42. Your Current '
          'Balance is ETB 145,200.00. Thank you for Banking with CBE! '
          'https://apps.cbe.com.et:100/?id=FT26195XKQ8T12341234';
      final p = parseReceiptText(raw, ownerAccountSuffix: owner);
      expect(p.amountCents, 500000);
      expect(p.type, TxType.credit);
      expect(p.reference, 'FT26195XKQ8T');
      expect(p.confidence, Confidence.high);
      expect(p.bank, isNull);
    });

    test('nothing recognisable still throws', () {
      expect(
        () => parseReceiptText('Thank you for shopping with us'),
        throwsA(isA<ParseException>()),
      );
    });
  });

  group('parseReceiptDate', () {
    test('every shape seen on the receipts', () {
      expect(
        parseReceiptDate('16/09/2026, 11:11:34'),
        DateTime(2026, 9, 16, 11, 11, 34),
      );
      expect(
        parseReceiptDate('14/07/2026 at 10:42'),
        DateTime(2026, 7, 14, 10, 42),
      );
      expect(parseReceiptDate('16/09/2026'), DateTime(2026, 9, 16));
      expect(
        parseReceiptDate('2026/09/17 16:37:36'),
        DateTime(2026, 9, 17, 16, 37, 36),
      );
      expect(
        parseReceiptDate('2026-09-17 03:28:03 PM'),
        DateTime(2026, 9, 17, 15, 28, 3),
      );
      expect(
        parseReceiptDate('2026-09-17 12:05:00 AM'),
        DateTime(2026, 9, 17, 0, 5),
      );
      expect(
        parseReceiptDate('Sep 15, 2026 03:38 PM'),
        DateTime(2026, 9, 15, 15, 38),
      );
      expect(
        parseReceiptDate('Sep 15, 2026, 3:38:00 pm'),
        DateTime(2026, 9, 15, 15, 38),
      );
      expect(
        parseReceiptDate('September 15, 2026 12:00 PM'),
        DateTime(2026, 9, 15, 12),
      );
      expect(parseReceiptDate('nonsense'), isNull);
      expect(parseReceiptDate('99/99/2026'), isNull);
    });
  });
}

/// M3 tests: ProfileInterpreter against the three bundled formats.
///
/// Each test loads the bundled profile JSON from disk (the same file shipped
/// as an asset) and runs it over a synthetic extracted-text fixture that
/// mirrors the structure of the real example documents. This is the
/// equivalent of a small-scale §14.1 "golden test" without needing the actual
/// example PDFs / screenshots checked into git.
import 'dart:convert';
import 'dart:io';

import 'package:budget/services/import/profile_interpreter.dart';
import 'package:budget/services/import/source_profile.dart';
import 'package:budget/services/import/text_extractor.dart';
import 'package:budget/services/import/transaction_draft.dart';
import 'package:flutter_test/flutter_test.dart';

SourceProfile _loadProfile(String filename) {
  final raw = File('assets/import/profiles/$filename').readAsStringSync();
  return SourceProfile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

ExtractedText _text(String s, {ExtractionSource source = ExtractionSource.mock}) =>
    ExtractedText(fullText: s, blocks: const [], source: source);

void main() {
  group('ProfileInterpreter — Scotiabank PDF', () {
    final profile = _loadProfile('scotiabank_pdf.json');

    test('parses rows between section markers and infers year from period', () {
      const text = '''
Scotia Momentum Visa Card
Statement Period
Apr 5, 2026 - May 4, 2026

REF.#
Transactions since your last statement
001 Apr 06 Apr 07 STARBUCKS TORONTO 12.50
002 Apr 10 Apr 11 LOBLAWS GROCERIES 87.25
003 Apr 15 Apr 16 PAYMENT - THANK YOU 500.00 -
SUB-TOTAL
Purchases/charges + \$99.75
Payments/credits - \$500.00
''';

      final result = ProfileInterpreter().interpret(
        profile,
        _text(text),
        fileSha: 'abc123',
      );

      expect(result.periodStart, DateTime(2026, 4, 5));
      expect(result.periodEnd, DateTime(2026, 5, 4));
      expect(result.drafts, hasLength(3));

      final r1 = result.drafts[0];
      expect(r1.date, DateTime(2026, 4, 6));
      expect(r1.amount, closeTo(12.50, 0.001));
      expect(r1.kind, DraftKind.expense);
      expect(r1.merchantNormalized, 'Starbucks Toronto');

      final r2 = result.drafts[1];
      expect(r2.amount, closeTo(87.25, 0.001));
      expect(r2.kind, DraftKind.expense);

      // Trailing dash → credit_flag → rule sets type=income → DraftKind.income.
      final r3 = result.drafts[2];
      expect(r3.amount, closeTo(500.00, 0.001));
      expect(r3.kind, DraftKind.income);
    });

    test('skip_when filters interest/fee/header noise lines', () {
      const text = '''
Statement Period
Apr 5, 2026 - May 4, 2026
REF.#
Transactions since your last statement
001 Apr 06 Apr 07 STARBUCKS 12.50
Interest charges this month
002 Apr 10 Apr 11 ANNUAL FEE 25.00
SUB-TOTAL
''';

      final result = ProfileInterpreter().interpret(
        profile,
        _text(text),
        fileSha: 'abc123',
      );
      // "Interest charges" and "ANNUAL FEE" lines are in skip_when.
      expect(result.drafts.map((d) => d.merchantNormalized),
          equals(['Starbucks']));
    });

    test('fingerprints differ across lines (so re-imports are detectable)', () {
      const text = '''
Statement Period
Apr 5, 2026 - May 4, 2026
REF.#
Transactions since your last statement
001 Apr 06 Apr 07 STARBUCKS 12.50
002 Apr 10 Apr 11 LOBLAWS 87.25
SUB-TOTAL
''';
      final result = ProfileInterpreter()
          .interpret(profile, _text(text), fileSha: 'abc123');
      final fps = result.drafts.map((d) => d.importFingerprint).toSet();
      expect(fps, hasLength(result.drafts.length));
      expect(fps.first, isNotEmpty);
    });
  });

  group('ProfileInterpreter — Wealthsimple PDF', () {
    final profile = _loadProfile('wealthsimple_pdf.json');

    test('parses rows; Payment becomes DraftKind.payment (excluded by default)',
        () {
      const text = '''
Wealthsimple Credit card statement
Activity
Apr 5 - May 4, 2026
TRANS. DATE POSTED DATE TYPE DETAILS AMOUNT (\$CAD)
Apr 06 Apr 07 Purchase STARBUCKS 4.50
Apr 10 Apr 11 Purchase LOBLAWS 87.25
Apr 15 Apr 16 Payment Payment received 200.00
Information about your Wealthsimple credit card
''';

      final result = ProfileInterpreter().interpret(
        profile,
        _text(text),
        fileSha: 'sha-ws-pdf',
      );

      expect(result.drafts, hasLength(3));
      expect(result.drafts[0].kind, DraftKind.expense);
      expect(result.drafts[0].amount, closeTo(4.50, 0.001));
      expect(result.drafts[0].date, DateTime(2026, 4, 6));

      // "Payment" type → DraftKind.payment, excluded by default per §6.5.
      final payment = result.drafts[2];
      expect(payment.kind, DraftKind.payment);
      expect(payment.include, isFalse,
          reason: 'CC payments are excluded by default '
              '(includeCcPayments=false)');
    });

    test('includeCcPayments=true keeps payment rows included', () {
      const text = '''
Wealthsimple Credit card statement
Apr 5 - May 4, 2026
TRANS. DATE POSTED DATE TYPE DETAILS
Apr 15 Apr 16 Payment Payment received 200.00
Information about your Wealthsimple
''';

      final result = ProfileInterpreter().interpret(
        profile,
        _text(text),
        fileSha: 'sha',
        includeCcPayments: true,
      );
      expect(result.drafts.single.kind, DraftKind.payment);
      expect(result.drafts.single.include, isTrue);
    });
  });

  group('ProfileInterpreter — Wealthsimple screenshot (windowed/image)', () {
    final profile = _loadProfile('wealthsimple_screenshot.json');

    test('image mode: date header above is applied to following rows', () {
      const text = '''
Wealthsimple
May 3, 2025
Coffee Shop - \$4.50 CAD
Some Other Shop - \$22.50 CAD
''';

      final result = ProfileInterpreter().interpret(
        profile,
        _text(text),
        fileSha: 'sha-ws-img',
      );

      expect(result.drafts, hasLength(2));
      expect(result.drafts[0].date, DateTime(2025, 5, 3));
      expect(result.drafts[0].amount, closeTo(4.50, 0.001));
      expect(result.drafts[0].merchantNormalized, 'Coffee Shop');
      expect(result.drafts[1].amount, closeTo(22.50, 0.001));
    });
  });
}

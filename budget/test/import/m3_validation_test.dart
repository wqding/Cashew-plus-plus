/// M3 tests: post-parse validation (design doc §6.3).
import 'package:budget/services/import/profile_interpreter.dart';
import 'package:budget/services/import/source_profile.dart';
import 'package:budget/services/import/transaction_draft.dart';
import 'package:budget/services/import/validation.dart';
import 'package:flutter_test/flutter_test.dart';

TransactionDraft _draft({
  DraftKind kind = DraftKind.expense,
  double amount = 10.0,
  DateTime? date,
  String? refNumber,
  String merchant = 'Coffee',
}) {
  return TransactionDraft(
    date: date ?? DateTime(2026, 4, 15),
    merchantNormalized: merchant,
    merchantRaw: merchant.toUpperCase(),
    amount: amount,
    kind: kind,
    rawSource: RawSourceRef(rawText: merchant, refNumber: refNumber),
    importFingerprint: 'fp-$merchant-$refNumber',
  );
}

SourceProfile _profile({TotalsValidation? totals}) {
  return SourceProfile(
    id: 'p',
    version: 1,
    displayName: 'p',
    sourceKind: SourceKind.pdf,
    match: const MatchRule(),
    row: const RowRule(regex: '.+', fields: {}),
    validation: ValidationRule(totals: totals),
  );
}

InterpretationResult _interp({DateTime? start, DateTime? end}) {
  return InterpretationResult(
    drafts: const [],
    unmatchedLines: const [],
    periodStart: start,
    periodEnd: end,
  );
}

void main() {
  group('Validator', () {
    test('passes a clean import (no errors)', () {
      final drafts = [_draft()];
      final result = Validator().validate(drafts, _profile(), _interp(), '');
      expect(result.passed, isTrue);
      expect(result.errors, isEmpty);
    });

    test('zero amount → zeroAmount error', () {
      final drafts = [_draft(amount: 0)];
      final result = Validator().validate(drafts, _profile(), _interp(), '');
      expect(result.passed, isFalse);
      expect(result.errors.single.kind, ValidationErrorKind.zeroAmount);
    });

    test('date outside period → dateOutsidePeriod error', () {
      final drafts = [
        _draft(date: DateTime(2026, 1, 1)), // way before period start
      ];
      final result = Validator().validate(
        drafts,
        _profile(),
        _interp(
          start: DateTime(2026, 4, 5),
          end: DateTime(2026, 5, 4),
        ),
        '',
      );
      expect(result.errors.single.kind, ValidationErrorKind.dateOutsidePeriod);
    });

    test('dates exactly on period boundaries are accepted', () {
      final drafts = [
        _draft(date: DateTime(2026, 4, 5)), // == period start
        _draft(date: DateTime(2026, 5, 4)), // == period end
      ];
      final result = Validator().validate(
        drafts,
        _profile(),
        _interp(
          start: DateTime(2026, 4, 5),
          end: DateTime(2026, 5, 4),
        ),
        '',
      );
      expect(
          result.errors.where(
              (e) => e.kind == ValidationErrorKind.dateOutsidePeriod),
          isEmpty);
    });

    test('duplicate ref numbers within one import → duplicateRef error', () {
      final drafts = [
        _draft(refNumber: '001', merchant: 'A'),
        _draft(refNumber: '001', merchant: 'B'),
      ];
      final result = Validator().validate(drafts, _profile(), _interp(), '');
      expect(
        result.errors.where(
            (e) => e.kind == ValidationErrorKind.duplicateRef),
        hasLength(1),
      );
    });

    test('totals mismatch (purchases) → totalsMismatch error', () {
      final drafts = [
        _draft(amount: 50.0, kind: DraftKind.expense),
        _draft(amount: 25.0, kind: DraftKind.expense),
      ];
      const fullText = 'Purchases/charges + \$100.00\nfooter';
      final profile = _profile(
        totals: const TotalsValidation(
          purchasesFieldRegex: r'Purchases/charges\s+\+\s+\$([\d,]+\.\d{2})',
        ),
      );
      final result =
          Validator().validate(drafts, profile, _interp(), fullText);
      // Parsed sum = $75.00, statement says $100.00 → mismatch.
      expect(
          result.errors.singleWhere(
              (e) => e.kind == ValidationErrorKind.totalsMismatch),
          isNotNull);
    });

    test('totals within \$0.01 tolerance → no error', () {
      final drafts = [_draft(amount: 100.0, kind: DraftKind.expense)];
      const fullText = 'Purchases/charges + \$100.00';
      final profile = _profile(
        totals: const TotalsValidation(
          purchasesFieldRegex: r'Purchases/charges\s+\+\s+\$([\d,]+\.\d{2})',
        ),
      );
      final result =
          Validator().validate(drafts, profile, _interp(), fullText);
      expect(result.passed, isTrue);
    });
  });
}

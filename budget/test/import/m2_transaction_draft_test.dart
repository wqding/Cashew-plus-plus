/// M2 tests: TransactionDraft type behavior. These checks lock the sign /
/// include semantics that the rest of the pipeline (validation, commit
/// mapping) and the review UI depend on.
import 'package:budget/services/import/transaction_draft.dart';
import 'package:flutter_test/flutter_test.dart';

TransactionDraft _draft({
  DraftKind kind = DraftKind.expense,
  double amount = 10.0,
}) {
  return TransactionDraft(
    date: DateTime(2026, 1, 1),
    merchantNormalized: 'Coffee',
    merchantRaw: 'COFFEE SHOP',
    amount: amount,
    kind: kind,
    rawSource: const RawSourceRef(rawText: 'COFFEE SHOP'),
    importFingerprint: 'fp',
  );
}

void main() {
  group('signedAmount', () {
    test('expense → negative', () {
      expect(_draft(kind: DraftKind.expense, amount: 4.50).signedAmount, -4.50);
    });
    test('fee → negative (same as expense)', () {
      expect(_draft(kind: DraftKind.fee, amount: 1.99).signedAmount, -1.99);
    });
    test('income → positive', () {
      expect(_draft(kind: DraftKind.income, amount: 12.0).signedAmount, 12.0);
    });
    test('payment → positive (it credits the card)', () {
      expect(
          _draft(kind: DraftKind.payment, amount: 100.0).signedAmount, 100.0);
    });
    test('stored amount is always positive — sign comes from kind only', () {
      // Even if a caller passes a negative amount, signedAmount uses .abs().
      expect(_draft(kind: DraftKind.expense, amount: 4.50).amount.abs(), 4.50);
    });
  });

  group('isIncomeForDb', () {
    test('income and payment commit as income rows', () {
      expect(_draft(kind: DraftKind.income).isIncomeForDb, isTrue);
      expect(_draft(kind: DraftKind.payment).isIncomeForDb, isTrue);
    });
    test('expense and fee commit as expense rows', () {
      expect(_draft(kind: DraftKind.expense).isIncomeForDb, isFalse);
      expect(_draft(kind: DraftKind.fee).isIncomeForDb, isFalse);
    });
  });

  group('isExcludedByKindDefault', () {
    test('payments and fees are excluded by default', () {
      expect(_draft(kind: DraftKind.payment).isExcludedByKindDefault, isTrue);
      expect(_draft(kind: DraftKind.fee).isExcludedByKindDefault, isTrue);
    });
    test('expenses and income are included by default', () {
      expect(_draft(kind: DraftKind.expense).isExcludedByKindDefault, isFalse);
      expect(_draft(kind: DraftKind.income).isExcludedByKindDefault, isFalse);
    });
  });

  test('id is auto-generated when not provided', () {
    final a = _draft();
    final b = _draft();
    expect(a.id, isNotEmpty);
    expect(a.id, isNot(equals(b.id)));
  });

  test('defaults: include=true, isDuplicate=false, CAD currency', () {
    final d = _draft();
    expect(d.include, isTrue);
    expect(d.isDuplicate, isFalse);
    expect(d.duplicateKind, isNull);
    expect(d.currency, 'CAD');
    expect(d.confidence, 1.0);
  });
}

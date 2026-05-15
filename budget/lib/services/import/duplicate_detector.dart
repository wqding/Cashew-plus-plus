/// Two-pass duplicate detection for imported transactions.
///
/// Pass 1 — exact fingerprint: zero false positives for re-importing the same
/// statement line.
/// Pass 2 — fuzzy: catches manual entries of the same transaction.
library;

import 'package:budget/services/import/transaction_draft.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:drift/drift.dart';

class DuplicateDetector {
  /// Annotates [drafts] in-place with [TransactionDraft.isDuplicate] and
  /// [TransactionDraft.duplicateKind]. Returns the same list for chaining.
  Future<List<TransactionDraft>> detect(List<TransactionDraft> drafts) async {
    await _passExact(drafts);
    await _passFuzzy(drafts);
    return drafts;
  }

  Future<void> _passExact(List<TransactionDraft> drafts) async {
    final fingerprints = drafts
        .where((d) => d.importFingerprint.isNotEmpty)
        .map((d) => d.importFingerprint)
        .toSet()
        .toList();
    if (fingerprints.isEmpty) return;

    // Query all fingerprints in one batch.
    final db = database;
    final existing = await (db.select(db.transactions)
          ..where((t) => t.importFingerprint.isIn(fingerprints)))
        .map((row) => row.importFingerprint)
        .get();
    final existingSet = existing.whereType<String>().toSet();

    for (final draft in drafts) {
      if (existingSet.contains(draft.importFingerprint)) {
        draft.isDuplicate = true;
        draft.duplicateKind = DuplicateKind.exactFingerprint;
        if (draft.include) draft.include = false;
      }
    }
  }

  Future<void> _passFuzzy(List<TransactionDraft> drafts) async {
    final db = database;
    // Only fuzzy-check drafts that are not already flagged.
    final candidates = drafts.where((d) => !d.isDuplicate).toList();

    for (final draft in candidates) {
      final wallet = draft.walletPk;
      final amount = draft.signedAmount;
      final name = draft.merchantNormalized.toLowerCase();
      final dateMin = draft.date.subtract(const Duration(days: 1));
      final dateMax = draft.date.add(const Duration(days: 1));

      final query = db.select(db.transactions)
        ..where((t) =>
            t.importFingerprint.isNull() &
            t.dateCreated.isBetweenValues(dateMin, dateMax) &
            t.amount.isBetweenValues(amount - 0.01, amount + 0.01) &
            t.name.lower().equals(name) &
            (wallet == null
                ? const Constant(true)
                : t.walletFk.equals(wallet)));
      final matches = await query.get();
      if (matches.isNotEmpty) {
        draft.isDuplicate = true;
        draft.duplicateKind = DuplicateKind.fuzzy;
        // Fuzzy duplicates are flagged but not excluded by default — the user
        // decides because two identical charges on the same day are possible.
      }
    }
  }
}

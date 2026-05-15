/// In-memory intermediate type produced by the import pipeline and consumed
/// by the review screen. One [TransactionDraft] becomes one row in the Drift
/// `Transactions` table on commit.
///
/// This type is intentionally decoupled from Drift's generated companion
/// types so that the pipeline can run before wallet/category resolution and
/// without holding the database open.
library;

import 'package:budget/struct/databaseGlobal.dart';

enum DuplicateKind {
  /// Exact match on `importFingerprint` — same statement line was previously
  /// imported.
  exactFingerprint,

  /// Soft match: same wallet, similar date, same amount, same normalized
  /// name — but the existing row was not imported (e.g. manual entry).
  fuzzy,
}

enum DraftKind {
  expense,
  income,
  /// CC payment, transfer, or other non-spending row. Excluded by default.
  payment,
  /// Bank fee or interest line. Excluded by default.
  fee,
}

/// Where a draft originated in the source document. Useful for the review
/// screen's "show raw text" affordance and for diagnostics.
class RawSourceRef {
  final int? pageIndex;
  final int? lineIndex;
  final String? refNumber;
  final String rawText;

  const RawSourceRef({
    this.pageIndex,
    this.lineIndex,
    this.refNumber,
    required this.rawText,
  });
}

class TransactionDraft {
  /// Stable id for the duration of a review session (not persisted).
  final String id;

  DateTime date;
  String merchantNormalized;
  final String merchantRaw;
  double amount;
  String currency;
  DraftKind kind;
  bool pending;

  /// `null` resolves to the default wallet at commit time.
  String? walletPk;

  /// `null` resolves to the default category at commit time.
  String? categoryPk;

  /// User toggle in the review screen.
  bool include;

  bool isDuplicate;
  DuplicateKind? duplicateKind;

  /// 0..1; rows below ~0.7 are highlighted in the review screen.
  double confidence;

  /// Extra information that should land in the transaction `note` on commit
  /// (FX details, ref number, pending tag, etc.).
  String? noteExtra;

  final RawSourceRef rawSource;

  /// sha256(fileSha + pageIndex + lineIndex/refNumber). Stored on the
  /// committed transaction to support deterministic dedup on re-import.
  final String importFingerprint;

  TransactionDraft({
    String? id,
    required this.date,
    required this.merchantNormalized,
    required this.merchantRaw,
    required this.amount,
    this.currency = "CAD",
    this.kind = DraftKind.expense,
    this.pending = false,
    this.walletPk,
    this.categoryPk,
    this.include = true,
    this.isDuplicate = false,
    this.duplicateKind,
    this.confidence = 1.0,
    this.noteExtra,
    required this.rawSource,
    required this.importFingerprint,
  }) : id = id ?? uuid.v4();

  bool get isExcludedByKindDefault =>
      kind == DraftKind.payment || kind == DraftKind.fee;

  /// Signed amount as Cashew stores it: expenses negative, income positive.
  double get signedAmount {
    switch (kind) {
      case DraftKind.expense:
      case DraftKind.fee:
        return -amount.abs();
      case DraftKind.income:
      case DraftKind.payment:
        return amount.abs();
    }
  }

  bool get isIncomeForDb =>
      kind == DraftKind.income || kind == DraftKind.payment;
}

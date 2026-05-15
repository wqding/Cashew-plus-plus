/// Top-level page for the "import transactions from screenshot / PDF" flow.
///
/// M2 walking skeleton: shows three hardcoded `TransactionDraft` rows and
/// commits them to the Drift database with `MethodAdded.import`. The real
/// pipeline (file picker, OCR/PDF extraction, profile matching) lands in M3.
library;

import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/pages/importReviewScreen.dart';
import 'package:budget/services/import/transaction_draft.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/navBarIconsData.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class AutoTransactionsPageImport extends StatefulWidget {
  const AutoTransactionsPageImport({super.key});

  @override
  State<AutoTransactionsPageImport> createState() =>
      _AutoTransactionsPageImportState();
}

class _AutoTransactionsPageImportState
    extends State<AutoTransactionsPageImport> {
  late final List<TransactionDraft> _drafts = _buildMockDrafts();
  bool _loadingDefaults = true;
  String? _defaultWalletPk;
  String? _defaultCategoryPk;

  @override
  void initState() {
    super.initState();
    _loadDefaults();
  }

  Future<void> _loadDefaults() async {
    final wallets = Provider.of<AllWallets>(context, listen: false);
    _defaultWalletPk = appStateSettings["selectedWalletPk"] as String? ??
        wallets.list.firstOrNull?.walletPk;
    final categories = await database.getAllCategories();
    _defaultCategoryPk = categories.firstOrNull?.categoryPk;
    if (mounted) setState(() => _loadingDefaults = false);
  }

  Future<void> _commit(List<TransactionDraft> included) async {
    if (_defaultWalletPk == null || _defaultCategoryPk == null) {
      openSnackbar(SnackbarMessage(
        title: "Can't import yet",
        description: "Create at least one account and category first.",
      ));
      return;
    }

    final now = DateTime.now();
    final companions = <TransactionsCompanion>[];
    for (final draft in included) {
      final note = _buildNote(draft);
      final companion = Transaction(
        transactionPk: "-1",
        name: draft.merchantNormalized,
        amount: draft.signedAmount,
        note: note,
        categoryFk: draft.categoryPk ?? _defaultCategoryPk!,
        walletFk: draft.walletPk ?? _defaultWalletPk!,
        dateCreated: draft.date,
        dateTimeModified: now,
        income: draft.isIncomeForDb,
        paid: true,
        skipPaid: false,
        methodAdded: MethodAdded.import,
        importFingerprint: draft.importFingerprint,
      ).toCompanion(true).copyWith(transactionPk: const Value.absent());
      companions.add(companion);
    }

    await database.createBatchTransactionsOnly(companions);

    openSnackbar(SnackbarMessage(
      icon: navBarIconsData["transactions"]!.iconData,
      title: "Imported ${companions.length} transactions",
    ));

    if (mounted) Navigator.of(context).pop();
  }

  String _buildNote(TransactionDraft draft) {
    final parts = <String>[];
    if (draft.pending) parts.add("[Pending]");
    if (draft.merchantRaw.isNotEmpty &&
        draft.merchantRaw != draft.merchantNormalized) {
      parts.add(draft.merchantRaw);
    }
    if (draft.noteExtra != null && draft.noteExtra!.isNotEmpty) {
      parts.add(draft.noteExtra!);
    }
    return parts.join(" • ");
  }

  @override
  Widget build(BuildContext context) {
    return PageFramework(
      title: "Import transactions",
      backButton: true,
      dragDownToDismiss: true,
      listWidgets: [
        if (_loadingDefaults)
          const Padding(
            padding: EdgeInsetsDirectional.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 20, 0),
            child: TextFont(
              text:
                  "Mocked import — three sample rows. Real file picker and parser arrive in M3.",
              fontSize: 13,
              maxLines: 4,
              textColor: getColor(context, "textLight"),
            ),
          ),
          const SizedBox(height: 8),
          ImportReviewList(
            drafts: _drafts,
            sourceLabel: "Mock walking skeleton",
            onConfirm: _commit,
          ),
        ],
      ],
    );
  }
}

List<TransactionDraft> _buildMockDrafts() {
  final today = DateTime.now();
  return [
    TransactionDraft(
      date: today,
      merchantNormalized: "Calgary Court Restaurant",
      merchantRaw: "CALGARY COURT RESTAURANT",
      amount: 56.11,
      currency: "CAD",
      kind: DraftKind.expense,
      pending: true,
      confidence: 0.95,
      importFingerprint: "mock-${today.millisecondsSinceEpoch}-1",
      rawSource: const RawSourceRef(
        pageIndex: 0,
        lineIndex: 1,
        rawText: "Calgary Court Restaurant  – \$56.11 CAD  Pending",
      ),
    ),
    TransactionDraft(
      date: today.subtract(const Duration(days: 1)),
      merchantNormalized: "Fenyk Coffee & Social",
      merchantRaw: "Sq *Fenyk Coffee & Social",
      amount: 10.49,
      currency: "CAD",
      kind: DraftKind.expense,
      confidence: 0.88,
      importFingerprint: "mock-${today.millisecondsSinceEpoch}-2",
      rawSource: const RawSourceRef(
        pageIndex: 0,
        lineIndex: 2,
        rawText: "Sq *Fenyk Coffee & Social  – \$10.49 CAD",
      ),
    ),
    TransactionDraft(
      date: today.subtract(const Duration(days: 2)),
      merchantNormalized: "Ab Dl Renewals",
      merchantRaw: "AB DL RENEWALS",
      amount: 98.00,
      currency: "CAD",
      kind: DraftKind.expense,
      confidence: 0.60,
      importFingerprint: "mock-${today.millisecondsSinceEpoch}-3",
      rawSource: const RawSourceRef(
        pageIndex: 0,
        lineIndex: 3,
        rawText: "Ab Dl Renewals  – \$98.00 CAD",
      ),
    ),
  ];
}

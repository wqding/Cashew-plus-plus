/// Review-screen widget for the import-from-file feature. Shows a list of
/// [TransactionDraft]s produced by the import pipeline; user toggles which
/// rows to include and edits values inline. The parent
/// (`AutoTransactionsPageImport`) handles the actual Drift commit.
///
/// M2 scope (walking skeleton): include checkbox, tap-to-edit name + amount,
/// pending / duplicate badges, totals header. Date / category / wallet
/// pickers land in M3 (T7c full implementation).
library;

import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/services/import/transaction_draft.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/tappable.dart';
import 'package:budget/widgets/textInput.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

class ImportReviewList extends StatefulWidget {
  const ImportReviewList({
    super.key,
    required this.drafts,
    required this.onConfirm,
    this.sourceLabel,
  });

  final List<TransactionDraft> drafts;
  final String? sourceLabel;

  /// Called when the user taps Confirm. Receives the list of included drafts
  /// in user-edited form.
  final Future<void> Function(List<TransactionDraft> included) onConfirm;

  @override
  State<ImportReviewList> createState() => _ImportReviewListState();
}

class _ImportReviewListState extends State<ImportReviewList> {
  bool _committing = false;

  List<TransactionDraft> get _included =>
      widget.drafts.where((d) => d.include).toList();

  double get _totalIncluded =>
      _included.fold(0.0, (sum, d) => sum + d.signedAmount);

  Future<void> _confirm() async {
    if (_committing) return;
    setState(() => _committing = true);
    try {
      await widget.onConfirm(_included);
    } finally {
      if (mounted) setState(() => _committing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final allWallets = Provider.of<AllWallets>(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReviewHeader(
          sourceLabel: widget.sourceLabel,
          includedCount: _included.length,
          totalCount: widget.drafts.length,
          totalLabel: convertToMoney(allWallets, _totalIncluded),
        ),
        Padding(
          padding: const EdgeInsetsDirectional.symmetric(horizontal: 8),
          child: Column(
            children: [
              for (final draft in widget.drafts)
                _DraftRow(
                  draft: draft,
                  onChanged: () => setState(() {}),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsetsDirectional.symmetric(horizontal: 16),
          child: Button(
            label: _committing
                ? "Importing…"
                : "Import ${_included.length} transactions",
            disabled: _committing || _included.isEmpty,
            onTap: _confirm,
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _ReviewHeader extends StatelessWidget {
  const _ReviewHeader({
    required this.sourceLabel,
    required this.includedCount,
    required this.totalCount,
    required this.totalLabel,
  });
  final String? sourceLabel;
  final int includedCount;
  final int totalCount;
  final String totalLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(20, 4, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (sourceLabel != null)
            TextFont(
              text: sourceLabel!,
              fontSize: 13,
              textColor: getColor(context, "textLight"),
            ),
          const SizedBox(height: 4),
          TextFont(
            text: "$includedCount of $totalCount selected • $totalLabel",
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ],
      ),
    );
  }
}

class _DraftRow extends StatelessWidget {
  const _DraftRow({required this.draft, required this.onChanged});
  final TransactionDraft draft;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final allWallets = Provider.of<AllWallets>(context);
    final dateLabel = DateFormat('MMM d, yyyy').format(draft.date);
    final amountLabel = convertToMoney(allWallets, draft.signedAmount);
    final isExcluded = !draft.include;
    final lowConfidence = draft.confidence < 0.7;

    return Container(
      margin: const EdgeInsetsDirectional.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: getColor(context, "lightDarkAccent"),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Tappable(
        borderRadius: 12,
        color: Colors.transparent,
        onTap: () {},
        child: Padding(
          padding: const EdgeInsetsDirectional.symmetric(
              horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Checkbox(
                value: draft.include,
                onChanged: (v) {
                  draft.include = v ?? false;
                  onChanged();
                },
              ),
              Expanded(
                child: Opacity(
                  opacity: isExcluded ? 0.45 : 1.0,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Tappable(
                              color: Colors.transparent,
                              borderRadius: 6,
                              onTap: () => _editName(context),
                              child: TextFont(
                                text: draft.merchantNormalized.isEmpty
                                    ? "(no name)"
                                    : draft.merchantNormalized,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                maxLines: 2,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Tappable(
                            color: Colors.transparent,
                            borderRadius: 6,
                            onTap: () => _editAmount(context),
                            child: TextFont(
                              text: amountLabel,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              textColor: draft.signedAmount < 0
                                  ? getColor(context, "expenseAmount")
                                  : getColor(context, "incomeAmount"),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          TextFont(
                            text: dateLabel,
                            fontSize: 12,
                            textColor: getColor(context, "textLight"),
                          ),
                          if (draft.pending) ...[
                            const SizedBox(width: 8),
                            const _Badge(label: "Pending"),
                          ],
                          if (draft.isDuplicate) ...[
                            const SizedBox(width: 8),
                            _Badge(
                              label: draft.duplicateKind ==
                                      DuplicateKind.exactFingerprint
                                  ? "Already imported"
                                  : "Similar exists",
                            ),
                          ],
                          if (lowConfidence) ...[
                            const SizedBox(width: 8),
                            const _Badge(
                              label: "Needs review",
                              isWarning: true,
                            ),
                          ],
                          if (draft.kind == DraftKind.payment) ...[
                            const SizedBox(width: 8),
                            const _Badge(label: "Payment"),
                          ],
                          if (draft.kind == DraftKind.fee) ...[
                            const SizedBox(width: 8),
                            const _Badge(label: "Fee"),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editName(BuildContext context) async {
    final result = await openBottomSheet(
      context,
      PopupFramework(
        title: "Edit name",
        child: _TextEditPopup(initialValue: draft.merchantNormalized),
      ),
    );
    if (result is String) {
      draft.merchantNormalized = result;
      onChanged();
    }
  }

  Future<void> _editAmount(BuildContext context) async {
    final result = await openBottomSheet(
      context,
      PopupFramework(
        title: "Edit amount",
        child: _TextEditPopup(
          initialValue: draft.amount.abs().toStringAsFixed(2),
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
        ),
      ),
    );
    if (result is String) {
      final parsed = double.tryParse(result.trim());
      if (parsed != null && parsed > 0) {
        draft.amount = parsed;
        onChanged();
      }
    }
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, this.isWarning = false});
  final String label;
  final bool isWarning;

  @override
  Widget build(BuildContext context) {
    final bg = isWarning
        ? Colors.orange.withOpacity(0.18)
        : Theme.of(context).colorScheme.secondary.withOpacity(0.22);
    final fg = isWarning
        ? Colors.orange.shade900
        : Theme.of(context).colorScheme.onSecondaryContainer;
    return Container(
      padding: const EdgeInsetsDirectional.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: TextFont(text: label, fontSize: 11, textColor: fg),
    );
  }
}

class _TextEditPopup extends StatefulWidget {
  const _TextEditPopup({
    required this.initialValue,
    this.keyboardType,
  });
  final String initialValue;
  final TextInputType? keyboardType;

  @override
  State<_TextEditPopup> createState() => _TextEditPopupState();
}

class _TextEditPopupState extends State<_TextEditPopup> {
  late String _value = widget.initialValue;
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextInput(
          controller: _controller,
          keyboardType: widget.keyboardType,
          autoFocus: true,
          onSubmitted: (v) {
            Navigator.of(context).pop(v);
          },
          onChanged: (v) => _value = v,
          labelText: "",
          padding: const EdgeInsetsDirectional.symmetric(horizontal: 8),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsetsDirectional.symmetric(horizontal: 8),
          child: Button(
            label: "Save",
            onTap: () => Navigator.of(context).pop(_value),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

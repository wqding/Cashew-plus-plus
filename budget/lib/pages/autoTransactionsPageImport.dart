/// Top-level page for the "import transactions from screenshot / PDF" flow.
///
/// M3: file picker → real ImportPipeline → review screen → commit.
library;

import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/pages/importReviewScreen.dart';
import 'package:budget/services/import/android/mlkit_text_extractor.dart';
import 'package:budget/services/import/android/syncfusion_pdf_extractor.dart';
import 'package:budget/services/import/import_pipeline.dart';
import 'package:budget/services/import/source_profile_store.dart';
import 'package:budget/services/import/transaction_draft.dart';
import 'package:budget/services/import/validation.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/navBarIconsData.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';

class AutoTransactionsPageImport extends StatefulWidget {
  const AutoTransactionsPageImport({super.key});

  @override
  State<AutoTransactionsPageImport> createState() =>
      _AutoTransactionsPageImportState();
}

class _AutoTransactionsPageImportState
    extends State<AutoTransactionsPageImport> {
  bool _loading = false;
  String _statusMessage = '';
  String? _errorMessage;
  String? _debugText;
  String? _matchedProfileForDebug;
  List<TransactionDraft>? _drafts;
  String? _profileLabel;
  ValidationResult? _validationResult;

  String? _defaultWalletPk;
  String? _defaultCategoryPk;

  final _profileStore = SourceProfileStore();

  @override
  void initState() {
    super.initState();
    _loadDefaults();
  }

  Future<void> _loadDefaults() async {
    final wallets = Provider.of<AllWallets>(context, listen: false);
    _defaultWalletPk = appStateSettings['selectedWalletPk'] as String? ??
        wallets.list.firstOrNull?.walletPk;
    final categories = await database.getAllCategories();
    _defaultCategoryPk = categories.firstOrNull?.categoryPk;
  }

  Future<void> _pickAndParse() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      if (mounted) {
        setState(() => _errorMessage = 'Could not read file data.');
      }
      return;
    }

    final fileName = file.name;
    final isPdf = fileName.toLowerCase().endsWith('.pdf');

    setState(() {
      _loading = true;
      _errorMessage = null;
      _debugText = null;
      _matchedProfileForDebug = null;
      _drafts = null;
      _statusMessage = 'Reading file…';
    });

    try {
      final textExtractor =
          isPdf ? SyncfusionPdfExtractor() : MlkitTextExtractor();

      final pipeline = ImportPipeline(
        textExtractor: textExtractor,
        profileStore: _profileStore,
      );

      final pipelineResult = await pipeline.run(
        bytes,
        fileName: fileName,
        onProgress: (status) {
          if (mounted) setState(() => _statusMessage = status);
        },
        includeCcPayments:
            appStateSettings['import_includeCcPayments'] as bool? ?? false,
        includeFees:
            appStateSettings['import_includeFees'] as bool? ?? false,
      );

      if (mounted) {
        setState(() {
          _loading = false;
          _drafts = pipelineResult.drafts;
          _profileLabel = pipelineResult.profileDisplayName;
          _validationResult = pipelineResult.validation;
        });
      }
    } on ImportPipelineException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _errorMessage = e.message;
          _debugText = e.debugText;
          _matchedProfileForDebug = e.matchedProfileName;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _errorMessage = 'Unexpected error: $e';
        });
      }
    }
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
        transactionPk: '-1',
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
      icon: navBarIconsData['transactions']!.iconData,
      title: 'Imported ${companions.length} transaction${companions.length == 1 ? '' : 's'}',
    ));

    if (mounted) Navigator.of(context).pop();
  }

  String _buildNote(TransactionDraft draft) {
    final parts = <String>[];
    if (draft.pending) parts.add('[Pending]');
    if (draft.merchantRaw.isNotEmpty &&
        draft.merchantRaw != draft.merchantNormalized) {
      parts.add(draft.merchantRaw);
    }
    if (draft.noteExtra != null && draft.noteExtra!.isNotEmpty) {
      parts.add(draft.noteExtra!);
    }
    return parts.join(' • ');
  }

  @override
  Widget build(BuildContext context) {
    return PageFramework(
      title: 'Import transactions',
      backButton: true,
      dragDownToDismiss: true,
      listWidgets: [
        if (_loading) ...[
          const SizedBox(height: 48),
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 16),
          Center(
            child: TextFont(
              text: _statusMessage,
              fontSize: 14,
              textColor: getColor(context, 'textLight'),
            ),
          ),
          const SizedBox(height: 48),
        ] else if (_drafts != null) ...[
          if (_validationResult != null &&
              _validationResult!.hasErrors) ...[
            _ValidationBanner(errors: _validationResult!.errors),
          ],
          ImportReviewList(
            drafts: _drafts!,
            sourceLabel: _profileLabel,
            onConfirm: _commit,
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton.icon(
              icon: const Icon(Icons.upload_file_outlined),
              label: const Text('Import another file'),
              onPressed: _pickAndParse,
            ),
          ),
          const SizedBox(height: 16),
        ] else ...[
          const SizedBox(height: 40),
          Center(
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(horizontal: 24),
              child: Column(
                children: [
                  Icon(
                    Icons.upload_file_outlined,
                    size: 64,
                    color: getColor(context, 'textLight').withOpacity(0.5),
                  ),
                  const SizedBox(height: 16),
                  TextFont(
                    text: 'Import from a PDF statement or screenshot',
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                  ),
                  const SizedBox(height: 8),
                  TextFont(
                    text:
                        'Supports Wealthsimple statements (PDF + screenshots) and Scotiabank credit card PDFs.',
                    fontSize: 13,
                    maxLines: 5,
                    textAlign: TextAlign.center,
                    textColor: getColor(context, 'textLight'),
                  ),
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsetsDirectional.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: TextFont(
                        text: _errorMessage!,
                        fontSize: 13,
                        maxLines: 8,
                        textColor: Colors.red.shade700,
                      ),
                    ),
                  ],
                  if (_debugText != null) ...[
                    const SizedBox(height: 12),
                    _DebugTextBlock(
                      text: _debugText!,
                      matchedProfile: _matchedProfileForDebug,
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    icon: const Icon(Icons.upload_file_outlined),
                    label: const Text('Choose file'),
                    onPressed: _pickAndParse,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 40),
        ],
      ],
    );
  }
}

class _DebugTextBlock extends StatelessWidget {
  const _DebugTextBlock({required this.text, this.matchedProfile});
  final String text;
  final String? matchedProfile;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsetsDirectional.all(12),
      decoration: BoxDecoration(
        color: getColor(context, 'lightDarkAccent'),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.text_snippet_outlined,
                size: 16,
                color: getColor(context, 'textLight'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextFont(
                  text: matchedProfile != null
                      ? 'Extracted text · matched profile: $matchedProfile'
                      : 'Extracted text · no profile matched',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  textColor: getColor(context, 'textLight'),
                ),
              ),
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Copied extracted text to clipboard'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: getColor(context, 'black').withOpacity(0.85),
                  height: 1.3,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ValidationBanner extends StatelessWidget {
  const _ValidationBanner({required this.errors});
  final List<ValidationError> errors;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 0),
      padding: const EdgeInsetsDirectional.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  color: Colors.orange.shade800, size: 18),
              const SizedBox(width: 8),
              TextFont(
                text: 'Validation warnings (${errors.length})',
                fontSize: 14,
                fontWeight: FontWeight.w600,
                textColor: Colors.orange.shade900,
              ),
            ],
          ),
          for (final e in errors.take(3)) ...[
            const SizedBox(height: 4),
            TextFont(
              text: '• ${e.message}',
              fontSize: 12,
              maxLines: 2,
              textColor: Colors.orange.shade900,
            ),
          ],
          if (errors.length > 3)
            TextFont(
              text: '…and ${errors.length - 3} more',
              fontSize: 12,
              textColor: Colors.orange.shade900,
            ),
        ],
      ),
    );
  }
}

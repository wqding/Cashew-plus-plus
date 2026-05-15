/// Orchestrates the full import pipeline (§6.1). The UI creates one
/// [ImportPipeline] per import session and calls [run].
///
/// Progress is reported via [onProgress] with a short human-readable status
/// string. Errors at any stage throw [ImportPipelineException], which the UI
/// surfaces as a snackbar or banner.
library;

import 'dart:developer' as developer;
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:budget/services/import/category_suggester.dart';
import 'package:budget/services/import/duplicate_detector.dart';
import 'package:budget/services/import/profile_interpreter.dart';
import 'package:budget/services/import/profile_matcher.dart';
import 'package:budget/services/import/source_profile.dart';
import 'package:budget/services/import/source_profile_store.dart';
import 'package:budget/services/import/text_extractor.dart';
import 'package:budget/services/import/transaction_draft.dart';
import 'package:budget/services/import/validation.dart';

/// Logger for the import pipeline. `developer.log` survives release builds and
/// shows up in `flutter run`'s console and in IDE log viewers.
void _log(String message, {Object? error, StackTrace? stackTrace}) {
  developer.log(message, name: 'import', error: error, stackTrace: stackTrace);
  // Also emit to plain stdout so it shows up unconditionally in the terminal
  // even when `developer.log` is filtered.
  // ignore: avoid_print
  print('[import] $message');
}

class ImportPipelineException implements Exception {
  final String message;

  /// First ~2000 chars of extracted text, if any. Surfaced in the UI so the
  /// user (or us) can see what was actually pulled from the file when no
  /// profile matched / 0 rows parsed. Null when extraction itself failed.
  final String? debugText;

  /// Name of the profile that was matched (if any) — useful when extraction
  /// succeeded and a profile matched but produced 0 rows.
  final String? matchedProfileName;

  const ImportPipelineException(
    this.message, {
    this.debugText,
    this.matchedProfileName,
  });

  @override
  String toString() => 'ImportPipelineException: $message';
}

class ImportPipelineResult {
  final List<TransactionDraft> drafts;

  /// The profile that was used, or null if LLM one-shot was used.
  final String? profileDisplayName;

  final ValidationResult validation;
  final InterpretationResult interpretation;

  const ImportPipelineResult({
    required this.drafts,
    required this.profileDisplayName,
    required this.validation,
    required this.interpretation,
  });
}

class ImportPipeline {
  final TextExtractor textExtractor;
  final SourceProfileStore profileStore;

  ImportPipeline({
    required this.textExtractor,
    required this.profileStore,
  });

  /// Runs the pipeline against [fileBytes] (a PNG/JPEG or PDF).
  ///
  /// [fileName] is used only to determine whether the file is an image or PDF.
  /// [onProgress] receives status strings for the loading indicator.
  Future<ImportPipelineResult> run(
    Uint8List fileBytes, {
    required String fileName,
    void Function(String status)? onProgress,
    bool includeCcPayments = false,
    bool includeFees = false,
  }) async {
    _log('──────── BEGIN import: $fileName (${fileBytes.length} bytes) ────────');
    _log('settings: includeCcPayments=$includeCcPayments includeFees=$includeFees');
    onProgress?.call('Extracting text…');

    final isPdf = fileName.toLowerCase().endsWith('.pdf');
    final fileKind = isPdf ? SourceKind.pdf : SourceKind.image;
    final fileSha = sha256.convert(fileBytes).toString();
    _log('file kind: $fileKind, sha256: ${fileSha.substring(0, 12)}…');

    ExtractedText extracted;
    try {
      if (isPdf) {
        extracted = await textExtractor.extractFromPdf(fileBytes);
      } else {
        extracted = await textExtractor.extractFromImage(fileBytes);
      }
    } on NoTextLayerException catch (e) {
      _log('extraction failed: NoTextLayerException', error: e);
      throw const ImportPipelineException(
        'This PDF has no readable text. Re-export as a text PDF, or screenshot each page.',
      );
    } catch (e, st) {
      _log('extraction failed', error: e, stackTrace: st);
      throw ImportPipelineException('Text extraction failed: $e');
    }

    _log('extracted ${extracted.fullText.length} chars in '
        '${extracted.blocks.length} blocks (source: ${extracted.source.name})');
    _logTextDump('--- EXTRACTED TEXT ---', extracted.fullText);

    if (extracted.fullText.trim().isEmpty) {
      _log('extraction produced empty text');
      throw const ImportPipelineException(
        'No text could be extracted from this file.',
      );
    }

    final debugSnippet = extracted.fullText.length > 2000
        ? extracted.fullText.substring(0, 2000) + '\n…(truncated)'
        : extracted.fullText;

    onProgress?.call('Detecting format…');
    final matcher = ProfileMatcher(profileStore);
    final matchResult =
        await matcher.match(extracted, fileKind: fileKind);

    if (matchResult == null) {
      _log('NO profile matched (loaded profiles: ${profileStore.listAll().map((p) => p.id).join(", ")})');
      throw ImportPipelineException(
        "Couldn't recognize this format. Enable LLM assistance in Settings to learn new formats.",
        debugText: debugSnippet,
      );
    }
    _log('matched profile: ${matchResult.profile.id} '
        '(${matchResult.profile.displayName}) — score ${matchResult.score}');

    onProgress?.call('Parsing transactions…');
    final interpreter = ProfileInterpreter();
    final interpretation = interpreter.interpret(
      matchResult.profile,
      extracted,
      fileSha: fileSha,
      includeCcPayments: includeCcPayments,
      includeFees: includeFees,
    );

    _log('parsed ${interpretation.drafts.length} drafts, '
        '${interpretation.unmatchedLines.length} unmatched lines');
    if (interpretation.periodStart != null && interpretation.periodEnd != null) {
      _log('detected period: ${interpretation.periodStart} → ${interpretation.periodEnd}');
    } else {
      _log('period: not detected');
    }
    for (final d in interpretation.drafts.take(20)) {
      _log('  draft: ${d.date.toIso8601String().substring(0, 10)}  '
          '${d.kind.name.padRight(7)}  '
          '${d.amount.toStringAsFixed(2).padLeft(10)}  '
          '${d.merchantNormalized}');
    }
    if (interpretation.unmatchedLines.isNotEmpty) {
      _log('first 10 unmatched lines:');
      for (final line in interpretation.unmatchedLines.take(10)) {
        _log('  · $line');
      }
    }

    if (interpretation.drafts.isEmpty) {
      throw ImportPipelineException(
        'No transactions could be parsed from this file. '
        'The format may be unsupported or the document may be empty.',
        debugText: debugSnippet,
        matchedProfileName: matchResult.profile.displayName,
      );
    }

    onProgress?.call('Normalizing merchants…');
    // Merchant normalization already happens inside ProfileInterpreter.

    onProgress?.call('Suggesting categories…');
    final categorySuggester = CategorySuggester();
    await categorySuggester.suggest(interpretation.drafts);

    onProgress?.call('Checking for duplicates…');
    final detector = DuplicateDetector();
    await detector.detect(interpretation.drafts);
    final dupCount =
        interpretation.drafts.where((d) => d.isDuplicate).length;
    _log('duplicate detector: $dupCount of ${interpretation.drafts.length} flagged');

    onProgress?.call('Validating…');
    final validator = Validator();
    final validationResult = validator.validate(
      interpretation.drafts,
      matchResult.profile,
      interpretation,
      extracted.fullText,
    );
    _log('validation: passed=${validationResult.passed}, '
        '${validationResult.errors.length} issues');
    for (final err in validationResult.errors) {
      _log('  ! [${err.kind.name}] ${err.message}');
    }

    _log('──────── END import: ${interpretation.drafts.length} drafts ready ────────');

    return ImportPipelineResult(
      drafts: interpretation.drafts,
      profileDisplayName: matchResult.profile.displayName,
      validation: validationResult,
      interpretation: interpretation,
    );
  }
}

/// Dumps a multi-line block to the log in chunks small enough to survive
/// Android logcat's per-line size limit (~4 KB).
void _logTextDump(String header, String body) {
  _log(header);
  const chunkLines = 40;
  final lines = body.split('\n');
  for (int i = 0; i < lines.length; i += chunkLines) {
    final end = (i + chunkLines).clamp(0, lines.length);
    final slice = lines.sublist(i, end).join('\n');
    // ignore: avoid_print
    print(slice);
  }
  _log('--- END $header ---');
}

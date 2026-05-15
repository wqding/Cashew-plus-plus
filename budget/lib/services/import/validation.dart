/// Post-parse validation layer (§6.3). Checks parsed drafts against profile
/// rules and emits a list of [ValidationError]s.
///
/// A validation failure does NOT abort the import. It sets an error banner on
/// the review screen, marks implicated rows, and triggers the LLM-repair path
/// in M4. In M3, errors are surfaced to the UI and the user may still confirm.
library;

import 'package:budget/services/import/profile_interpreter.dart';
import 'package:budget/services/import/source_profile.dart';
import 'package:budget/services/import/transaction_draft.dart';

enum ValidationErrorKind {
  totalsMismatch,
  dateOutsidePeriod,
  duplicateRef,
  zeroAmount,
}

class ValidationError {
  final ValidationErrorKind kind;
  final String message;
  final String? draftId;

  const ValidationError({
    required this.kind,
    required this.message,
    this.draftId,
  });
}

class ValidationResult {
  final bool passed;
  final List<ValidationError> errors;

  const ValidationResult({required this.passed, required this.errors});

  bool get hasErrors => errors.isNotEmpty;
}

class Validator {
  ValidationResult validate(
    List<TransactionDraft> drafts,
    SourceProfile profile,
    InterpretationResult interpretation,
    String fullText,
  ) {
    final errors = <ValidationError>[];

    // 1. No zero amounts.
    for (final d in drafts) {
      if (d.amount <= 0) {
        errors.add(ValidationError(
          kind: ValidationErrorKind.zeroAmount,
          message: 'Zero or negative amount: ${d.merchantNormalized}',
          draftId: d.id,
        ));
      }
    }

    // 2. All dates within period.
    final start = interpretation.periodStart;
    final end = interpretation.periodEnd;
    if (start != null && end != null) {
      for (final d in drafts) {
        final dateOnly = DateTime(d.date.year, d.date.month, d.date.day);
        final periodEndDay = DateTime(end.year, end.month, end.day);
        final periodStartDay = DateTime(start.year, start.month, start.day);
        if (dateOnly.isBefore(periodStartDay) ||
            dateOnly.isAfter(periodEndDay)) {
          errors.add(ValidationError(
            kind: ValidationErrorKind.dateOutsidePeriod,
            message:
                '${d.merchantNormalized} date ${d.date.toIso8601String()} outside period',
            draftId: d.id,
          ));
        }
      }
    }

    // 3. No duplicate ref numbers within the same import.
    final seenRefs = <String>{};
    for (final d in drafts) {
      final ref = d.rawSource.refNumber;
      if (ref != null && ref.isNotEmpty) {
        if (!seenRefs.add(ref)) {
          errors.add(ValidationError(
            kind: ValidationErrorKind.duplicateRef,
            message: 'Duplicate ref number $ref in this import',
            draftId: d.id,
          ));
        }
      }
    }

    // 4. Totals reconciliation.
    final totals = profile.validation.totals;
    if (totals != null) {
      errors.addAll(_checkTotals(totals, drafts, fullText));
    }

    return ValidationResult(passed: errors.isEmpty, errors: errors);
  }

  List<ValidationError> _checkTotals(
    TotalsValidation totals,
    List<TransactionDraft> drafts,
    String fullText,
  ) {
    final errors = <ValidationError>[];
    const tolerance = 0.01;

    if (totals.purchasesFieldRegex != null) {
      final re = RegExp(totals.purchasesFieldRegex!);
      final m = re.firstMatch(fullText);
      if (m != null) {
        final stated =
            double.tryParse(m.group(1)!.replaceAll(',', '')) ?? 0.0;
        final computed = drafts
            .where((d) =>
                d.kind == DraftKind.expense || d.kind == DraftKind.fee)
            .fold<double>(0.0, (sum, d) => sum + d.amount);
        if ((computed - stated).abs() > tolerance) {
          errors.add(ValidationError(
            kind: ValidationErrorKind.totalsMismatch,
            message:
                'Purchases total mismatch: parsed \$${computed.toStringAsFixed(2)}, '
                'statement says \$${stated.toStringAsFixed(2)}',
          ));
        }
      }
    }

    if (totals.creditsFieldRegex != null) {
      final re = RegExp(totals.creditsFieldRegex!);
      final m = re.firstMatch(fullText);
      if (m != null) {
        final stated =
            double.tryParse(m.group(1)!.replaceAll(',', '')) ?? 0.0;
        final computed = drafts
            .where((d) =>
                d.kind == DraftKind.income || d.kind == DraftKind.payment)
            .fold<double>(0.0, (sum, d) => sum + d.amount);
        if ((computed - stated).abs() > tolerance) {
          errors.add(ValidationError(
            kind: ValidationErrorKind.totalsMismatch,
            message:
                'Credits total mismatch: parsed \$${computed.toStringAsFixed(2)}, '
                'statement says \$${stated.toStringAsFixed(2)}',
          ));
        }
      }
    }

    return errors;
  }
}

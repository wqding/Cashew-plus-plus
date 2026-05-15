/// Runs a [SourceProfile] against [ExtractedText] to produce a list of
/// [TransactionDraft]s. This is the heuristic heart of the import pipeline;
/// no LLM is involved here.
///
/// Execution order per document:
///   1. Detect statement period (dates) from [SourceProfile.period].
///   2. Slice to the configured [SourceProfile.section].
///   3. Build "candidate windows" — either one line at a time (windowSize=1)
///      or sliding windows of N consecutive non-empty lines (windowSize>1).
///   4. Skip lines / windows matching [SourceProfile.skipWhen].
///   5. Try row regex against each window; on match, extract fields.
///   6. Evaluate conditional rules.
///   7. Emit [TransactionDraft].
library;

import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:budget/services/import/merchant_normalizer.dart';
import 'package:budget/services/import/source_profile.dart';
import 'package:budget/services/import/text_extractor.dart';
import 'package:budget/services/import/transaction_draft.dart';

class InterpretationResult {
  final List<TransactionDraft> drafts;

  /// Lines from the section that the row regex did not match (for diagnostics).
  final List<String> unmatchedLines;

  /// Detected period start/end, if the profile declared a period regex.
  final DateTime? periodStart;
  final DateTime? periodEnd;

  const InterpretationResult({
    required this.drafts,
    required this.unmatchedLines,
    this.periodStart,
    this.periodEnd,
  });
}

class ProfileInterpreter {
  /// [fileSha] is the sha256 hex of the original file bytes, used as part of
  /// the [TransactionDraft.importFingerprint].
  InterpretationResult interpret(
    SourceProfile profile,
    ExtractedText extracted, {
    required String fileSha,
    bool includeCcPayments = false,
    bool includeFees = false,
  }) {
    final text = extracted.fullText;
    final lines = text.split('\n');

    // 1. Detect period.
    DateTime? periodStart;
    DateTime? periodEnd;
    if (profile.period != null) {
      final pd = _parsePeriod(profile.period!, text);
      periodStart = pd?.$1;
      periodEnd = pd?.$2;
    }

    // 2. Slice to section.
    final sectionLines = _sliceSection(profile.section, lines);

    // 3-7. Parse rows using window-based matching.
    final drafts = <TransactionDraft>[];
    final unmatched = <String>[];

    final isImage = profile.sourceKind == SourceKind.image;
    final windowSize = profile.row.windowSize;

    if (windowSize > 1 || isImage) {
      _parseWindowed(
        profile: profile,
        sectionLines: sectionLines,
        periodStart: periodStart,
        periodEnd: periodEnd,
        fileSha: fileSha,
        includeCcPayments: includeCcPayments,
        includeFees: includeFees,
        drafts: drafts,
        unmatched: unmatched,
      );
    } else {
      _parseLineByLine(
        profile: profile,
        sectionLines: sectionLines,
        periodStart: periodStart,
        periodEnd: periodEnd,
        fileSha: fileSha,
        includeCcPayments: includeCcPayments,
        includeFees: includeFees,
        drafts: drafts,
        unmatched: unmatched,
      );
    }

    return InterpretationResult(
      drafts: drafts,
      unmatchedLines: unmatched,
      periodStart: periodStart,
      periodEnd: periodEnd,
    );
  }

  // ---------------------------------------------------------------------------
  // Line-by-line parsing (PDF profiles)
  // ---------------------------------------------------------------------------

  void _parseLineByLine({
    required SourceProfile profile,
    required List<String> sectionLines,
    required DateTime? periodStart,
    required DateTime? periodEnd,
    required String fileSha,
    required bool includeCcPayments,
    required bool includeFees,
    required List<TransactionDraft> drafts,
    required List<String> unmatched,
  }) {
    final rowRegex = RegExp(profile.row.regex, multiLine: true);
    final skipSubstrings = profile.skipWhen.anySubstring;
    int lineIndex = 0;

    for (final line in sectionLines) {
      final trimmed = line.trim();
      lineIndex++;
      if (trimmed.isEmpty) continue;
      if (_shouldSkip(trimmed, skipSubstrings)) continue;

      final match = rowRegex.firstMatch(trimmed);
      if (match == null) {
        unmatched.add(trimmed);
        continue;
      }

      final draft = _buildDraft(
        match: match,
        matchedText: trimmed,
        profile: profile,
        periodStart: periodStart,
        periodEnd: periodEnd,
        fileSha: fileSha,
        lineIndex: lineIndex,
        currentDateHeader: null,
        includeCcPayments: includeCcPayments,
        includeFees: includeFees,
      );
      if (draft != null) drafts.add(draft);
    }
  }

  // ---------------------------------------------------------------------------
  // Windowed parsing (image/screenshot profiles with windowSize > 1)
  // ---------------------------------------------------------------------------

  void _parseWindowed({
    required SourceProfile profile,
    required List<String> sectionLines,
    required DateTime? periodStart,
    required DateTime? periodEnd,
    required String fileSha,
    required bool includeCcPayments,
    required bool includeFees,
    required List<TransactionDraft> drafts,
    required List<String> unmatched,
  }) {
    final rowRegex = RegExp(profile.row.regex, multiLine: true, dotAll: true);
    final skipSubstrings = profile.skipWhen.anySubstring;
    final windowSize = profile.row.windowSize.clamp(1, 10);

    // Filter non-empty lines and detect date headers.
    final nonEmptyLines = <_IndexedLine>[];
    DateTime? currentDateHeader;

    for (int i = 0; i < sectionLines.length; i++) {
      final trimmed = sectionLines[i].trim();
      if (trimmed.isEmpty) continue;

      final headerDate = _tryDateHeader(trimmed);
      if (headerDate != null) {
        currentDateHeader = headerDate;
        continue;
      }

      nonEmptyLines.add(_IndexedLine(
        text: trimmed,
        lineIndex: i,
        dateHeader: currentDateHeader,
      ));
    }

    // Slide a window of `windowSize` lines. When a window matches, advance by
    // window size to avoid overlapping matches.
    int i = 0;
    while (i < nonEmptyLines.length) {
      final end = (i + windowSize).clamp(0, nonEmptyLines.length);
      final window = nonEmptyLines.sublist(i, end);

      // Skip windows where every line hits the skip list.
      if (window.every((l) => _shouldSkip(l.text, skipSubstrings))) {
        i++;
        continue;
      }

      final windowText = window.map((l) => l.text).join('\n');
      final match = rowRegex.firstMatch(windowText);
      if (match != null) {
        final draft = _buildDraft(
          match: match,
          matchedText: windowText,
          profile: profile,
          periodStart: periodStart,
          periodEnd: periodEnd,
          fileSha: fileSha,
          lineIndex: window.first.lineIndex,
          currentDateHeader: window.first.dateHeader,
          includeCcPayments: includeCcPayments,
          includeFees: includeFees,
        );
        if (draft != null) {
          drafts.add(draft);
          i += windowSize;
          continue;
        }
      }

      // No match for this window start position.
      if (window.isNotEmpty && !_shouldSkip(window.first.text, skipSubstrings)) {
        unmatched.add(window.first.text);
      }
      i++;
    }
  }

  // ---------------------------------------------------------------------------
  // Common draft construction
  // ---------------------------------------------------------------------------

  TransactionDraft? _buildDraft({
    required RegExpMatch match,
    required String matchedText,
    required SourceProfile profile,
    required DateTime? periodStart,
    required DateTime? periodEnd,
    required String fileSha,
    required int lineIndex,
    required DateTime? currentDateHeader,
    required bool includeCcPayments,
    required bool includeFees,
  }) {
    final fields = profile.row.fields;
    final values = <String, dynamic>{};

    for (final entry in fields.entries) {
      final spec = entry.value;
      final raw = spec.group <= match.groupCount ? match.group(spec.group) : null;
      if (raw == null) continue;
      values[entry.key] = _parseFieldValue(raw, spec.kind);
    }

    // Determine transaction date.
    DateTime? date = values['trans_date'] as DateTime?;
    date ??= values['date'] as DateTime?;

    // Use image date header when available.
    if (profile.sourceKind == SourceKind.image && currentDateHeader != null) {
      date = currentDateHeader;
    }

    // Infer year for date_md fields.
    if (date != null && date.year == _kNoYear) {
      date = _inferYear(date, periodStart, periodEnd,
          yearStrategy: profile.period?.yearStrategy ?? 'from_period_end');
    }

    if (date == null) return null;

    final merchantRaw = (values['merchant'] as String? ?? '').trim();
    final amount = (values['amount'] as double?) ?? 0.0;
    if (amount <= 0) return null;

    DraftKind kind = DraftKind.expense;
    final creditFlag = values['credit_flag'] as bool? ?? false;
    if (creditFlag) kind = DraftKind.income;

    final typeParsed = values['type'] as String?;
    if (typeParsed != null) {
      final t = typeParsed.toLowerCase();
      if (t.contains('payment')) {
        kind = DraftKind.payment;
      } else if (t.contains('refund') || t.contains('credit')) {
        kind = DraftKind.income;
      } else if (t.contains('fee') || t.contains('interest')) {
        kind = DraftKind.fee;
      }
    }

    // Rules form an if / else_set chain. A rule with no `if` is a
    // fallthrough that fires only when no earlier `if`-rule matched.
    bool anyConditionMet = false;
    for (final rule in profile.row.rules) {
      final condition = rule['if'] as String?;
      final thenSet = rule['then_set'] as Map<String, dynamic>?;
      final elseSet = rule['else_set'] as Map<String, dynamic>?;

      Map<String, dynamic>? apply;
      if (condition != null) {
        final condVal = values[condition];
        final conditionMet = condVal == true ||
            (condVal is String && condVal.isNotEmpty) ||
            (condVal is double && condVal != 0.0);
        if (conditionMet) {
          apply = thenSet;
          anyConditionMet = true;
        } else if (elseSet != null) {
          apply = elseSet;
        }
      } else if (!anyConditionMet) {
        // Fallthrough rule.
        apply = elseSet ?? thenSet;
      }

      if (apply != null) {
        final t = apply['type'] as String?;
        if (t == 'income' || t == 'credit') kind = DraftKind.income;
        if (t == 'debit') kind = DraftKind.expense;
        if (t == 'payment') kind = DraftKind.payment;
        if (t == 'fee') kind = DraftKind.fee;
      }
    }

    bool include = true;
    if (kind == DraftKind.payment && !includeCcPayments) include = false;
    if (kind == DraftKind.fee && !includeFees) include = false;

    final isPending = values['pending'] as bool? ??
        (values['status'] as String?)?.toLowerCase().contains('pending') == true ||
        matchedText.toLowerCase().contains('pending');

    final refNumber = values['ref'] as String?;
    final fingerprint = _fingerprint(fileSha, lineIndex, refNumber);
    final merchantNorm = MerchantNormalizer.normalize(merchantRaw);

    final currency = values['currency'] as String? ?? 'CAD';
    String? noteExtra = currency != 'CAD' ? currency : null;

    return TransactionDraft(
      date: date,
      merchantNormalized: merchantNorm,
      merchantRaw: merchantRaw,
      amount: amount,
      currency: currency,
      kind: kind,
      pending: isPending,
      include: include,
      confidence: _rowConfidence(merchantRaw, amount, date),
      noteExtra: noteExtra,
      rawSource: RawSourceRef(
        pageIndex: 0,
        lineIndex: lineIndex,
        refNumber: refNumber,
        rawText: matchedText,
      ),
      importFingerprint: fingerprint,
    );
  }

  // ---------------------------------------------------------------------------
  // Period parsing
  // ---------------------------------------------------------------------------

  static const int _kNoYear = 1;

  static (DateTime, DateTime)? _parsePeriod(PeriodRule period, String text) {
    try {
      final re = RegExp(period.regex, caseSensitive: false);
      final m = re.firstMatch(text);
      if (m == null) return null;
      final start = _parseDateFlexible(m.group(1)!.trim());
      final end = _parseDateFlexible(m.group(2)!.trim());
      if (start == null || end == null) return null;

      // If only the end date carries a year (e.g. "Apr 5 — May 4, 2026"),
      // copy it onto the start. Roll back a year if the start month is
      // after the end month (Dec → Jan boundary).
      DateTime resolvedStart = start;
      if (start.year == _kNoYear && end.year != _kNoYear) {
        int year = end.year;
        if (start.month > end.month) year = end.year - 1;
        resolvedStart = DateTime(year, start.month, start.day);
      }
      return (resolvedStart, end);
    } catch (_) {
      return null;
    }
  }

  static DateTime? _parseDateFlexible(String s) {
    // "May 3, 2025"
    final full = RegExp(
      r'^(\w{3})\s+(\d{1,2}),?\s+(\d{4})$',
      caseSensitive: false,
    );
    var m = full.firstMatch(s);
    if (m != null) {
      final month = _monthNum(m.group(1)!);
      final day = int.parse(m.group(2)!);
      final year = int.parse(m.group(3)!);
      if (month != null) return DateTime(year, month, day);
    }
    // "May 3" — no year.
    final monthDay = RegExp(r'^(\w{3})\s+(\d{1,2})$', caseSensitive: false);
    m = monthDay.firstMatch(s);
    if (m != null) {
      final month = _monthNum(m.group(1)!);
      final day = int.tryParse(m.group(2)!);
      if (month != null && day != null) return DateTime(_kNoYear, month, day);
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Year inference for date_md fields
  // ---------------------------------------------------------------------------

  static DateTime _inferYear(
    DateTime noYearDate,
    DateTime? periodStart,
    DateTime? periodEnd, {
    required String yearStrategy,
  }) {
    if (periodEnd == null && periodStart == null) {
      return DateTime(DateTime.now().year, noYearDate.month, noYearDate.day);
    }
    final refEnd = periodEnd ?? DateTime.now();
    final refStart = periodStart ?? refEnd;

    int year;
    if (yearStrategy == 'from_period_start') {
      year = refStart.year;
    } else {
      // Default: from_period_end; Dec→Jan boundary correction.
      year = refEnd.year;
      if (noYearDate.month > refEnd.month) year = refStart.year;
    }
    return DateTime(year, noYearDate.month, noYearDate.day);
  }

  // ---------------------------------------------------------------------------
  // Field value parsing
  // ---------------------------------------------------------------------------

  static dynamic _parseFieldValue(String raw, FieldKind kind) {
    switch (kind) {
      case FieldKind.amount:
        return _parseAmount(raw);
      case FieldKind.dateMd:
        return _parseDateMd(raw);
      case FieldKind.dateMdy:
        return _parseDateFlexible(raw);
      case FieldKind.flagPresent:
        return raw.trim().isNotEmpty;
      case FieldKind.string:
        return raw.trim();
    }
  }

  static double? _parseAmount(String raw) {
    // Strip currency, separators, and PDF extraction artifacts (embedded
    // spaces between digits, e.g. "$1 1.03" → "$11.03").
    var cleaned = raw
        .replaceAll(',', '')
        .replaceAll('\$', '')
        .replaceAll(' ', '')
        .replaceAll(' ', '') // non-breaking space
        .trim();
    // Normalize unicode dashes to ASCII minus.
    cleaned = cleaned.replaceAll('–', '-').replaceAll('—', '-');
    if (cleaned.endsWith('-')) {
      return double.tryParse(
          cleaned.substring(0, cleaned.length - 1).trim())?.abs();
    }
    if (cleaned.startsWith('-')) {
      return double.tryParse(cleaned.substring(1))?.abs();
    }
    return double.tryParse(cleaned)?.abs();
  }

  static DateTime? _parseDateMd(String raw) {
    final re = RegExp(r'^(\w{3})\s+(\d{1,2})$', caseSensitive: false);
    final m = re.firstMatch(raw.trim());
    if (m == null) return null;
    final month = _monthNum(m.group(1)!);
    final day = int.tryParse(m.group(2)!);
    if (month == null || day == null) return null;
    return DateTime(_kNoYear, month, day);
  }

  static int? _monthNum(String abbr) {
    const months = {
      'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
      'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
    };
    if (abbr.length < 3) return null;
    return months[abbr.toLowerCase().substring(0, 3)];
  }

  // ---------------------------------------------------------------------------
  // Section slicing
  // ---------------------------------------------------------------------------

  static List<String> _sliceSection(
      SectionRule? section, List<String> lines) {
    if (section == null) return lines;

    final startRe = section.startRegex != null
        ? RegExp(section.startRegex!, multiLine: true)
        : null;
    final endRe = section.endRegex != null
        ? RegExp(section.endRegex!, multiLine: true)
        : null;

    int start = 0;
    int end = lines.length;

    if (startRe != null) {
      for (int i = 0; i < lines.length; i++) {
        if (startRe.hasMatch(lines[i])) {
          start = i + 1;
          break;
        }
      }
    }

    if (endRe != null) {
      for (int i = start; i < lines.length; i++) {
        if (endRe.hasMatch(lines[i])) {
          end = i;
          break;
        }
      }
    }

    return lines.sublist(start, end);
  }

  // ---------------------------------------------------------------------------
  // Skip rules
  // ---------------------------------------------------------------------------

  static bool _shouldSkip(String line, List<String> substrings) {
    for (final s in substrings) {
      if (line.contains(s)) return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Date header detection (Wealthsimple screenshot)
  // ---------------------------------------------------------------------------

  static final _todayRe = RegExp(r'^Today$', caseSensitive: false);
  static final _yesterdayRe = RegExp(r'^Yesterday$', caseSensitive: false);
  static final _fullDateRe = RegExp(
    r'^(\w{3,9})\s+(\d{1,2}),?\s+(\d{4})$',
    caseSensitive: false,
  );

  static DateTime? _tryDateHeader(String line) {
    if (_todayRe.hasMatch(line)) {
      final now = DateTime.now();
      return DateTime(now.year, now.month, now.day);
    }
    if (_yesterdayRe.hasMatch(line)) {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      return DateTime(yesterday.year, yesterday.month, yesterday.day);
    }
    final m = _fullDateRe.firstMatch(line);
    if (m != null) {
      final month = _monthNum(m.group(1)!);
      final day = int.tryParse(m.group(2)!);
      final year = int.tryParse(m.group(3)!);
      if (month != null && day != null && year != null) {
        return DateTime(year, month, day);
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Fingerprint
  // ---------------------------------------------------------------------------

  static String _fingerprint(
      String fileSha, int lineIndex, String? refNumber) {
    final payload = refNumber != null && refNumber.isNotEmpty
        ? '$fileSha:ref:$refNumber'
        : '$fileSha:line:$lineIndex';
    return sha256.convert(utf8.encode(payload)).toString();
  }

  // ---------------------------------------------------------------------------
  // Row confidence
  // ---------------------------------------------------------------------------

  static double _rowConfidence(
      String merchant, double amount, DateTime date) {
    double score = 1.0;
    if (merchant.isEmpty) score -= 0.4;
    if (amount <= 0) score -= 0.3;
    if (date.year == _kNoYear) score -= 0.2;
    return score.clamp(0.0, 1.0);
  }
}

class _IndexedLine {
  final String text;
  final int lineIndex;
  final DateTime? dateHeader;
  const _IndexedLine({
    required this.text,
    required this.lineIndex,
    this.dateHeader,
  });
}

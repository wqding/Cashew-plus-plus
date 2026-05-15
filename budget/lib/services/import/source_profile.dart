/// Declarative description of one import-source format (e.g. "Scotiabank PDF",
/// "Wealthsimple screenshot"). Profiles are JSON documents shipped as assets
/// or produced/repaired by the local LLM. The [ProfileInterpreter] (T5c)
/// runs a profile against extracted text to produce `TransactionDraft`s.
///
/// Schema mirrors `assets/import/source_profile_schema.json`. Keep both in
/// sync — the JSON schema is also the input to the GBNF grammar used to
/// constrain LLM output.
library;

enum SourceKind { image, pdf, unknown }

SourceKind sourceKindFromString(String s) {
  switch (s) {
    case 'image':
      return SourceKind.image;
    case 'pdf':
      return SourceKind.pdf;
    default:
      return SourceKind.unknown;
  }
}

enum FieldKind {
  string,
  amount,
  /// "Mon DD" — year inferred from period header.
  dateMd,
  /// "Mon DD, YYYY" — full date in the source.
  dateMdy,
  /// Capture-group presence is the value (true if non-empty).
  flagPresent,
}

FieldKind fieldKindFromString(String s) {
  switch (s) {
    case 'amount':
      return FieldKind.amount;
    case 'date_md':
      return FieldKind.dateMd;
    case 'date_mdy':
      return FieldKind.dateMdy;
    case 'flag_present':
      return FieldKind.flagPresent;
    case 'string':
    default:
      return FieldKind.string;
  }
}

class FieldSpec {
  final int group;
  final FieldKind kind;
  const FieldSpec({required this.group, this.kind = FieldKind.string});

  factory FieldSpec.fromJson(Map<String, dynamic> j) => FieldSpec(
        group: j['group'] as int,
        kind: fieldKindFromString(j['kind'] as String? ?? 'string'),
      );
  Map<String, dynamic> toJson() => {
        'group': group,
        if (kind != FieldKind.string) 'kind': _fieldKindToString(kind),
      };
}

String _fieldKindToString(FieldKind k) {
  switch (k) {
    case FieldKind.amount:
      return 'amount';
    case FieldKind.dateMd:
      return 'date_md';
    case FieldKind.dateMdy:
      return 'date_mdy';
    case FieldKind.flagPresent:
      return 'flag_present';
    case FieldKind.string:
      return 'string';
  }
}

class MatchRule {
  final List<String> keywordsAll;
  final List<String> keywordsAny;
  final List<SourceKind> filetypes;

  const MatchRule({
    this.keywordsAll = const [],
    this.keywordsAny = const [],
    this.filetypes = const [],
  });

  factory MatchRule.fromJson(Map<String, dynamic> j) => MatchRule(
        keywordsAll: (j['keywords_all'] as List?)?.cast<String>() ?? const [],
        keywordsAny: (j['keywords_any'] as List?)?.cast<String>() ?? const [],
        filetypes: (j['filetypes'] as List?)
                ?.map((e) => sourceKindFromString(e as String))
                .toList() ??
            const [],
      );

  Map<String, dynamic> toJson() => {
        if (keywordsAll.isNotEmpty) 'keywords_all': keywordsAll,
        if (keywordsAny.isNotEmpty) 'keywords_any': keywordsAny,
        if (filetypes.isNotEmpty)
          'filetypes':
              filetypes.map((e) => e.toString().split('.').last).toList(),
      };
}

class PeriodRule {
  final String regex;
  // 'from_period_start' or 'from_period_end' — for spans like Apr→May, which
  // year applies to which trans-date.
  final String yearStrategy;

  const PeriodRule({required this.regex, this.yearStrategy = 'from_period_end'});

  factory PeriodRule.fromJson(Map<String, dynamic> j) => PeriodRule(
        regex: j['regex'] as String,
        yearStrategy:
            j['year_strategy'] as String? ?? 'from_period_end',
      );
  Map<String, dynamic> toJson() =>
      {'regex': regex, 'year_strategy': yearStrategy};
}

class SectionRule {
  final String? startRegex;
  final String? endRegex;

  const SectionRule({this.startRegex, this.endRegex});

  factory SectionRule.fromJson(Map<String, dynamic> j) => SectionRule(
        startRegex: j['start_regex'] as String?,
        endRegex: j['end_regex'] as String?,
      );
  Map<String, dynamic> toJson() => {
        if (startRegex != null) 'start_regex': startRegex,
        if (endRegex != null) 'end_regex': endRegex,
      };
}

class SkipRule {
  final List<String> anySubstring;
  const SkipRule({this.anySubstring = const []});

  factory SkipRule.fromJson(Map<String, dynamic> j) => SkipRule(
        anySubstring:
            (j['any_substring'] as List?)?.cast<String>() ?? const [],
      );
  Map<String, dynamic> toJson() =>
      anySubstring.isEmpty ? {} : {'any_substring': anySubstring};
}

class RowRule {
  final String regex;
  final Map<String, FieldSpec> fields;
  // Simple if/then-set rules evaluated in order. Each rule sets values on the
  // emitted draft. Format intentionally minimal for v1.
  final List<Map<String, dynamic>> rules;

  const RowRule({
    required this.regex,
    required this.fields,
    this.rules = const [],
  });

  factory RowRule.fromJson(Map<String, dynamic> j) {
    final fieldsJson = j['fields'] as Map<String, dynamic>? ?? const {};
    return RowRule(
      regex: j['regex'] as String,
      fields: fieldsJson.map(
        (k, v) => MapEntry(k, FieldSpec.fromJson(v as Map<String, dynamic>)),
      ),
      rules: ((j['rules'] as List?) ?? const [])
          .cast<Map<String, dynamic>>(),
    );
  }

  Map<String, dynamic> toJson() => {
        'regex': regex,
        'fields': fields.map((k, v) => MapEntry(k, v.toJson())),
        if (rules.isNotEmpty) 'rules': rules,
      };
}

class TotalsValidation {
  final String? purchasesFieldRegex;
  final String? creditsFieldRegex;

  const TotalsValidation({this.purchasesFieldRegex, this.creditsFieldRegex});

  factory TotalsValidation.fromJson(Map<String, dynamic> j) =>
      TotalsValidation(
        purchasesFieldRegex: j['purchases_field_regex'] as String?,
        creditsFieldRegex: j['credits_field_regex'] as String?,
      );
  Map<String, dynamic> toJson() => {
        if (purchasesFieldRegex != null)
          'purchases_field_regex': purchasesFieldRegex,
        if (creditsFieldRegex != null) 'credits_field_regex': creditsFieldRegex,
      };
}

class ValidationRule {
  final TotalsValidation? totals;
  const ValidationRule({this.totals});

  factory ValidationRule.fromJson(Map<String, dynamic> j) => ValidationRule(
        totals: j['totals'] == null
            ? null
            : TotalsValidation.fromJson(j['totals'] as Map<String, dynamic>),
      );
  Map<String, dynamic> toJson() =>
      totals == null ? {} : {'totals': totals!.toJson()};
}

class SourceProfile {
  final String id;
  final int version;
  final String displayName;
  final SourceKind sourceKind;
  final MatchRule match;
  final PeriodRule? period;
  final SectionRule? section;
  final RowRule row;
  final SkipRule skipWhen;
  final ValidationRule validation;

  const SourceProfile({
    required this.id,
    required this.version,
    required this.displayName,
    required this.sourceKind,
    required this.match,
    required this.row,
    this.period,
    this.section,
    this.skipWhen = const SkipRule(),
    this.validation = const ValidationRule(),
  });

  factory SourceProfile.fromJson(Map<String, dynamic> j) => SourceProfile(
        id: j['id'] as String,
        version: j['version'] as int? ?? 1,
        displayName: j['display_name'] as String? ?? j['id'] as String,
        sourceKind:
            sourceKindFromString(j['source_kind'] as String? ?? 'pdf'),
        match: MatchRule.fromJson(
            (j['match'] as Map<String, dynamic>?) ?? const {}),
        period: j['period'] == null
            ? null
            : PeriodRule.fromJson(j['period'] as Map<String, dynamic>),
        section: j['section'] == null
            ? null
            : SectionRule.fromJson(j['section'] as Map<String, dynamic>),
        row: RowRule.fromJson(j['row'] as Map<String, dynamic>),
        skipWhen: j['skip_when'] == null
            ? const SkipRule()
            : SkipRule.fromJson(j['skip_when'] as Map<String, dynamic>),
        validation: j['validation'] == null
            ? const ValidationRule()
            : ValidationRule.fromJson(
                j['validation'] as Map<String, dynamic>),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'version': version,
        'display_name': displayName,
        'source_kind': sourceKind.toString().split('.').last,
        'match': match.toJson(),
        if (period != null) 'period': period!.toJson(),
        if (section != null) 'section': section!.toJson(),
        'row': row.toJson(),
        if (skipWhen.anySubstring.isNotEmpty) 'skip_when': skipWhen.toJson(),
        if (validation.totals != null) 'validation': validation.toJson(),
      };
}

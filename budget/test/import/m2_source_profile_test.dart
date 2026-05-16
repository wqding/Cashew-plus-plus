/// M2 tests: SourceProfile JSON contract.
///
/// Verifies:
///   - Round-trip parsing of a SourceProfile JSON document.
///   - All bundled profile JSON files parse successfully and expose the
///     expected ids / source kinds. The bundled profiles are the contract
///     the rest of the pipeline relies on, so a broken JSON should fail loudly.
import 'dart:convert';
import 'dart:io';

import 'package:budget/services/import/source_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SourceProfile.fromJson round-trip', () {
    const json = r'''
    {
      "id": "test_v1",
      "version": 2,
      "display_name": "Test profile",
      "source_kind": "pdf",
      "match": {
        "keywords_all": ["Statement Period"],
        "keywords_any": ["Visa", "Mastercard"],
        "filetypes": ["pdf"]
      },
      "period": {
        "regex": "(\\w{3} \\d{1,2}, \\d{4})\\s*-\\s*(\\w{3} \\d{1,2}, \\d{4})",
        "year_strategy": "from_period_end"
      },
      "section": {
        "start_regex": "Transactions",
        "end_regex": "SUB-TOTAL"
      },
      "row": {
        "regex": "^(\\d{3})\\s+(.+?)\\s+([\\d.]+)$",
        "fields": {
          "ref":      { "group": 1 },
          "merchant": { "group": 2, "kind": "string" },
          "amount":   { "group": 3, "kind": "amount" }
        },
        "rules": [
          { "if": "credit_flag", "then_set": { "type": "credit" } }
        ],
        "window_size": 3
      },
      "skip_when": {
        "any_substring": ["Interest charges"]
      },
      "validation": {
        "totals": {
          "purchases_field_regex": "Purchases\\s+\\$([\\d.]+)",
          "credits_field_regex":   "Credits\\s+\\$([\\d.]+)"
        }
      }
    }
    ''';

    test('parses every top-level field', () {
      final p = SourceProfile.fromJson(jsonDecode(json) as Map<String, dynamic>);

      expect(p.id, 'test_v1');
      expect(p.version, 2);
      expect(p.displayName, 'Test profile');
      expect(p.sourceKind, SourceKind.pdf);

      expect(p.match.keywordsAll, ['Statement Period']);
      expect(p.match.keywordsAny, ['Visa', 'Mastercard']);
      expect(p.match.filetypes, [SourceKind.pdf]);

      expect(p.period?.yearStrategy, 'from_period_end');
      expect(p.section?.startRegex, 'Transactions');
      expect(p.section?.endRegex, 'SUB-TOTAL');

      expect(p.row.fields['ref']?.kind, FieldKind.string);
      expect(p.row.fields['amount']?.kind, FieldKind.amount);
      expect(p.row.windowSize, 3);
      expect(p.row.rules, hasLength(1));

      expect(p.skipWhen.anySubstring, ['Interest charges']);
      expect(p.validation.totals?.purchasesFieldRegex, isNotNull);
      expect(p.validation.totals?.creditsFieldRegex, isNotNull);
    });

    test('survives a toJson → fromJson cycle (no data loss)', () {
      final original =
          SourceProfile.fromJson(jsonDecode(json) as Map<String, dynamic>);
      final re = SourceProfile.fromJson(original.toJson());

      expect(re.id, original.id);
      expect(re.version, original.version);
      expect(re.sourceKind, original.sourceKind);
      expect(re.match.keywordsAll, original.match.keywordsAll);
      expect(re.row.windowSize, original.row.windowSize);
      expect(re.row.fields.keys, original.row.fields.keys);
      expect(re.skipWhen.anySubstring, original.skipWhen.anySubstring);
    });

    test('defaults are applied when optional fields are absent', () {
      final minimal = SourceProfile.fromJson({
        'id': 'minimal',
        'row': {
          'regex': '.+',
          'fields': {'amount': {'group': 1, 'kind': 'amount'}}
        }
      });
      expect(minimal.version, 1);
      expect(minimal.displayName, 'minimal');
      expect(minimal.sourceKind, SourceKind.pdf);
      expect(minimal.match.keywordsAll, isEmpty);
      expect(minimal.row.windowSize, 1);
      expect(minimal.skipWhen.anySubstring, isEmpty);
      expect(minimal.validation.totals, isNull);
    });
  });

  group('Bundled profile JSON files', () {
    // Run from the budget/ working dir (default for `flutter test`).
    const profilesDir = 'assets/import/profiles';

    void expectParsesAs(String filename, String id, SourceKind kind) {
      test('$filename → id=$id, kind=$kind', () {
        final raw = File('$profilesDir/$filename').readAsStringSync();
        final p = SourceProfile.fromJson(
            jsonDecode(raw) as Map<String, dynamic>);
        expect(p.id, id);
        expect(p.sourceKind, kind);
        expect(p.match.keywordsAll, isNotEmpty,
            reason: 'a bundled profile without keywords_all would match '
                'every document and dominate the matcher score');
      });
    }

    expectParsesAs(
        'scotiabank_pdf.json', 'scotiabank_pdf_v1', SourceKind.pdf);
    expectParsesAs(
        'wealthsimple_pdf.json', 'wealthsimple_pdf_v1', SourceKind.pdf);
    expectParsesAs('wealthsimple_screenshot.json',
        'wealthsimple_screenshot_v1', SourceKind.image);
  });
}

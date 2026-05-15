/// Three-tier category suggestion for imported transactions (§6.5):
///   1. History lookup — most-recently-created transaction with the same
///      normalized merchant name in the user's existing data.
///   2. Bundled dictionary — static merchant→category-name map shipped as an
///      asset. Maps to a category by display-name substring match.
///   3. Default category from the `import_defaultCategoryPk` setting.
library;

import 'dart:convert';
import 'package:budget/services/import/transaction_draft.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:drift/drift.dart';
import 'package:flutter/services.dart' show rootBundle;

class CategorySuggester {
  Map<String, String>? _dictionary; // normalized name → category display name

  Future<void> ensureLoaded() async {
    if (_dictionary != null) return;
    try {
      final raw = await rootBundle
          .loadString('assets/import/merchant_categories.json');
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _dictionary = json
          .map((k, v) => MapEntry(k, v.toString()))
        ..remove('_comment');
    } catch (_) {
      _dictionary = {};
    }
  }

  /// Annotates [drafts] in-place with [TransactionDraft.categoryPk] using the
  /// three-tier resolution. Returns the same list for chaining.
  Future<List<TransactionDraft>> suggest(List<TransactionDraft> drafts) async {
    await ensureLoaded();

    final defaultPk =
        appStateSettings['import_defaultCategoryPk'] as String?;

    // Batch: collect all unique normalized merchant names.
    final names = drafts
        .map((d) => d.merchantNormalized.toLowerCase())
        .toSet();

    // Pass 1 — history lookup (one query per unique name).
    final historyMap = <String, String>{};
    for (final name in names) {
      final pk = await _lookupHistory(name);
      if (pk != null) historyMap[name] = pk;
    }

    // Pass 2 — dictionary (all categories, keyed by display name).
    final allCategories = await database.getAllCategories();
    final catByName = <String, String>{};
    for (final c in allCategories) {
      catByName[c.name.toLowerCase()] = c.categoryPk;
    }

    for (final draft in drafts) {
      if (draft.categoryPk != null) continue;
      final lower = draft.merchantNormalized.toLowerCase();

      // Tier 1: history.
      final fromHistory = historyMap[lower];
      if (fromHistory != null) {
        draft.categoryPk = fromHistory;
        continue;
      }

      // Tier 2: dictionary.
      final dictName = _dictionary![lower];
      if (dictName != null) {
        final pk = catByName[dictName.toLowerCase()];
        if (pk != null) {
          draft.categoryPk = pk;
          continue;
        }
        // Try substring match for flexibility (e.g. "Food & Dining" → "Food").
        for (final entry in catByName.entries) {
          if (dictName.toLowerCase().contains(entry.key) ||
              entry.key.contains(dictName.toLowerCase())) {
            draft.categoryPk = entry.value;
            break;
          }
        }
        if (draft.categoryPk != null) continue;
      }

      // Tier 3: default.
      draft.categoryPk = defaultPk;
    }
    return drafts;
  }

  Future<String?> _lookupHistory(String normalizedLower) async {
    final db = database;
    final rows = await (db.select(db.transactions)
          ..where((t) => t.name.lower().equals(normalizedLower))
          ..orderBy([(t) => OrderingTerm.desc(t.dateCreated)])
          ..limit(1))
        .get();
    return rows.firstOrNull?.categoryFk;
  }
}

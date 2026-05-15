/// Loads, caches, and persists [SourceProfile] documents.
///
/// Bundled profiles ship as Flutter assets under
/// `assets/import/profiles/*.json`. Learned profiles (produced by the LLM in
/// M4) are written to the app-support directory and loaded alongside bundled
/// ones.
library;

import 'dart:convert';
import 'dart:io';

import 'package:budget/services/import/source_profile.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

const _bundledProfileAssets = [
  'assets/import/profiles/wealthsimple_screenshot.json',
  'assets/import/profiles/wealthsimple_pdf.json',
  'assets/import/profiles/scotiabank_pdf.json',
  'assets/import/profiles/generic_cc_pdf.json',
];

class SourceProfileStore {
  final List<SourceProfile> _profiles = [];
  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    await _loadBundled();
    await _loadLearned();
  }

  Future<void> _loadBundled() async {
    for (final path in _bundledProfileAssets) {
      try {
        final raw = await rootBundle.loadString(path);
        final json = jsonDecode(raw) as Map<String, dynamic>;
        _profiles.add(SourceProfile.fromJson(json));
      } catch (e) {
        // Asset missing or malformed — skip; store carries the rest.
      }
    }
  }

  Future<Directory> _learnedDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/import_profiles');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<void> _loadLearned() async {
    final dir = await _learnedDir();
    for (final entity in dir.listSync()) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final raw = entity.readAsStringSync();
          final json = jsonDecode(raw) as Map<String, dynamic>;
          _profiles.add(SourceProfile.fromJson(json));
        } catch (_) {}
      }
    }
  }

  List<SourceProfile> listAll() => List.unmodifiable(_profiles);

  /// Saves a learned profile to disk, replacing any existing entry with the
  /// same [SourceProfile.id] in the in-memory list.
  Future<void> save(SourceProfile profile) async {
    final dir = await _learnedDir();
    final file = File('${dir.path}/learned_${profile.id}.json');
    file.writeAsStringSync(jsonEncode(profile.toJson()));

    final idx = _profiles.indexWhere((p) => p.id == profile.id);
    if (idx >= 0) {
      _profiles[idx] = profile;
    } else {
      _profiles.add(profile);
    }
  }

  Future<void> delete(String profileId) async {
    final dir = await _learnedDir();
    final file = File('${dir.path}/learned_$profileId.json');
    if (file.existsSync()) file.deleteSync();
    _profiles.removeWhere((p) => p.id == profileId);
  }
}

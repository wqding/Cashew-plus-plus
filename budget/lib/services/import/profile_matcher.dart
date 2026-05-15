/// Picks the best-fit [SourceProfile] for an [ExtractedText] document.
///
/// Scoring (from design doc §6.2):
///   +10 per keywords_all hit (must hit ALL to be eligible).
///    +1 per keywords_any hit.
///    +5 if filetype matches.
///    +5 if section.start_regex matches anywhere in the text.
///
/// Best score wins. Ties broken by version (newest first).
/// If the winner scores 0, returns null → escalate to LLM authoring.
library;

import 'package:budget/services/import/source_profile.dart';
import 'package:budget/services/import/source_profile_store.dart';
import 'package:budget/services/import/text_extractor.dart';

class ProfileMatch {
  final SourceProfile profile;
  final int score;
  const ProfileMatch({required this.profile, required this.score});
}

class ProfileMatcher {
  final SourceProfileStore store;
  const ProfileMatcher(this.store);

  /// Returns the best-matching profile, or null if no profile scores above 0.
  Future<ProfileMatch?> match(
    ExtractedText extracted, {
    required SourceKind fileKind,
  }) async {
    await store.ensureLoaded();
    final text = extracted.fullText;

    ProfileMatch? best;
    for (final profile in store.listAll()) {
      final score = _score(profile, text, fileKind);
      if (score <= 0) continue;
      if (best == null ||
          score > best.score ||
          (score == best.score && profile.version > best.profile.version)) {
        best = ProfileMatch(profile: profile, score: score);
      }
    }
    return best;
  }

  int _score(SourceProfile profile, String text, SourceKind fileKind) {
    final match = profile.match;

    // keywords_all: ALL must be present; if any miss, disqualify.
    for (final kw in match.keywordsAll) {
      if (!text.contains(kw)) return 0;
    }

    int score = match.keywordsAll.length * 10;

    for (final kw in match.keywordsAny) {
      if (text.contains(kw)) score += 1;
    }

    if (match.filetypes.contains(fileKind)) score += 5;

    final sectionStart = profile.section?.startRegex;
    if (sectionStart != null) {
      try {
        if (RegExp(sectionStart, multiLine: true).hasMatch(text)) score += 5;
      } catch (_) {}
    }

    return score;
  }
}

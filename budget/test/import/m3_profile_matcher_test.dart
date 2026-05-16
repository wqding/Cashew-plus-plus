/// M3 tests: ProfileMatcher scoring (design doc §6.2).
///
/// +10 per keywords_all hit (must hit ALL to be eligible)
///  +1 per keywords_any hit
///  +5 if filetype matches
///  +5 if section.start_regex matches anywhere in the text
/// Ties broken by version (newer first); zero score → null (escalate).
import 'package:budget/services/import/profile_matcher.dart';
import 'package:budget/services/import/source_profile.dart';
import 'package:budget/services/import/source_profile_store.dart';
import 'package:budget/services/import/text_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeStore extends SourceProfileStore {
  final List<SourceProfile> profiles;
  _FakeStore(this.profiles);
  @override
  Future<void> ensureLoaded() async {}
  @override
  List<SourceProfile> listAll() => List.unmodifiable(profiles);
}

SourceProfile _profile({
  required String id,
  int version = 1,
  SourceKind sourceKind = SourceKind.pdf,
  List<String> keywordsAll = const [],
  List<String> keywordsAny = const [],
  List<SourceKind> filetypes = const [],
  String? sectionStart,
}) {
  return SourceProfile(
    id: id,
    version: version,
    displayName: id,
    sourceKind: sourceKind,
    match: MatchRule(
      keywordsAll: keywordsAll,
      keywordsAny: keywordsAny,
      filetypes: filetypes,
    ),
    section: sectionStart == null
        ? null
        : SectionRule(startRegex: sectionStart),
    row: const RowRule(regex: '.+', fields: {}),
  );
}

ExtractedText _text(String s) => ExtractedText(
      fullText: s,
      blocks: const [],
      source: ExtractionSource.mock,
    );

void main() {
  group('ProfileMatcher.match', () {
    test('keywords_all must ALL hit, otherwise profile is disqualified',
        () async {
      final p = _profile(
        id: 'scotia',
        keywordsAll: ['Scotia', 'Momentum'],
        filetypes: [SourceKind.pdf],
      );
      final matcher = ProfileMatcher(_FakeStore([p]));

      final hit = await matcher.match(
        _text('Scotia Momentum statement'),
        fileKind: SourceKind.pdf,
      );
      expect(hit, isNotNull);
      expect(hit!.profile.id, 'scotia');

      final miss = await matcher.match(
        _text('Scotia statement only'),
        fileKind: SourceKind.pdf,
      );
      expect(miss, isNull, reason: 'missing one keywords_all term disqualifies');
    });

    test('score sums correctly: 10*all + 1*any + 5*filetype + 5*section', () async {
      final p = _profile(
        id: 'p',
        keywordsAll: ['Foo', 'Bar'], // +20
        keywordsAny: ['Baz', 'Qux'], // +2
        filetypes: [SourceKind.pdf], // +5
        sectionStart: 'BEGIN', // +5
      );
      final matcher = ProfileMatcher(_FakeStore([p]));
      final m = await matcher.match(
        _text('Foo Bar Baz Qux\nBEGIN'),
        fileKind: SourceKind.pdf,
      );
      expect(m, isNotNull);
      expect(m!.score, 32);
    });

    test('returns null when no profile scores above 0', () async {
      final p = _profile(id: 'unmatched', keywordsAll: ['Never']);
      final matcher = ProfileMatcher(_FakeStore([p]));
      final m = await matcher.match(
        _text('nothing relevant here'),
        fileKind: SourceKind.pdf,
      );
      expect(m, isNull);
    });

    test('best score wins; ties broken by higher version', () async {
      final older = _profile(id: 'p_v1', version: 1, keywordsAll: ['Foo']);
      final newer = _profile(id: 'p_v2', version: 2, keywordsAll: ['Foo']);
      final matcher = ProfileMatcher(_FakeStore([older, newer]));
      final m = await matcher.match(
        _text('Foo bar baz'),
        fileKind: SourceKind.pdf,
      );
      expect(m, isNotNull);
      expect(m!.profile.id, 'p_v2');
    });

    test('filetype mismatch costs +5; profile may still win on other points',
        () async {
      final pdfOnly = _profile(
        id: 'pdfOnly',
        keywordsAll: ['Doc'],
        filetypes: [SourceKind.pdf],
      );
      final matcher = ProfileMatcher(_FakeStore([pdfOnly]));
      final asImage = await matcher.match(
        _text('Doc'),
        fileKind: SourceKind.image,
      );
      // Still wins (keywords_all gave it 10), just without the +5 bonus.
      expect(asImage, isNotNull);
      expect(asImage!.score, 10);
    });
  });
}

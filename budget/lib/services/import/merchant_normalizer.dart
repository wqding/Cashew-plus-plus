/// Pure-Dart merchant name normalizer. Applied to every import source after
/// raw text extraction, before category lookup or duplicate detection.
library;

class MerchantNormalizer {
  static final _processorPrefixes = RegExp(
    r'^(SQ\s?\*|TST-|TST\*|GOOGLE\s*\*|FACEBK\s*\*|[A-Z]{2,4}\*\d+-|'
    r'PAYPAL\s*\*|AMZN\s+MKTPLCE?\*?|AMZN\s+)',
    caseSensitive: false,
  );

  static final _phoneNumber = RegExp(r'\b\d{3}-?\d{3}-?\d{4}\b');

  static final _provinceCode = RegExp(
    r'\b(AB|BC|ON|QC|MB|SK|NS|NB|PE|NL|YT|NT|NU)\s*$',
    caseSensitive: false,
  );

  static final _storeNumber = RegExp(r'\s*#\d+\s*$');

  static final _whitespace = RegExp(r'\s+');

  /// Normalizes [raw] into a clean, title-cased merchant name.
  ///
  /// Steps (from the design doc §6.4):
  /// 1. Strip processor prefixes.
  /// 2. Strip trailing phone numbers.
  /// 3. Strip trailing province codes.
  /// 4. Strip trailing store numbers.
  /// 5. Title-case and collapse whitespace.
  static String normalize(String raw) {
    var s = raw.trim();
    s = s.replaceFirst(_processorPrefixes, '').trim();
    s = s.replaceAll(_phoneNumber, '').trim();
    s = s.replaceAll(_provinceCode, '').trim();
    s = s.replaceAll(_storeNumber, '').trim();
    s = _titleCase(s.replaceAll(_whitespace, ' '));
    return s;
  }

  static String _titleCase(String s) {
    if (s.isEmpty) return s;
    return s.split(' ').map((word) {
      if (word.isEmpty) return word;
      return word[0].toUpperCase() + word.substring(1).toLowerCase();
    }).join(' ');
  }
}

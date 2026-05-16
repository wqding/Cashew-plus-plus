/// M1 tests: schema changes (MethodAdded.import enum value + importFingerprint
/// nullable column on Transactions, schema v47).
import 'package:budget/database/tables.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('M1 — MethodAdded enum', () {
    test('contains `import` value', () {
      expect(MethodAdded.values, contains(MethodAdded.import));
    });

    test('`import` is at index 5 (append-only; persisted as int)', () {
      // MethodAdded is stored as `intEnum<MethodAdded>()` in the
      // Categories/Transactions tables. Re-ordering or inserting values
      // would silently re-map existing rows in production DBs.
      expect(MethodAdded.import.index, 5);
    });

    test('existing values keep their indices', () {
      expect(MethodAdded.email.index, 0);
      expect(MethodAdded.shared.index, 1);
      expect(MethodAdded.csv.index, 2);
      expect(MethodAdded.preview.index, 3);
      expect(MethodAdded.appLink.index, 4);
    });
  });

  group('M1 — schema version', () {
    test('schemaVersionGlobal bumped to 47 for importFingerprint migration', () {
      expect(schemaVersionGlobal, 47);
    });
  });
}

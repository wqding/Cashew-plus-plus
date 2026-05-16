/// M3 tests: MerchantNormalizer (design doc §6.4).
import 'package:budget/services/import/merchant_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Table-driven: each pair exercises one of the normalization steps.
  const cases = <List<String>>[
    // [input, expected]
    ['', ''],
    ['STARBUCKS', 'Starbucks'],
    ['  COFFEE   SHOP   ', 'Coffee Shop'],

    // Processor prefixes (§6.4 step 1).
    ['SQ *COFFEE SHOP', 'Coffee Shop'],
    ['SQ*BAKERY', 'Bakery'],
    ['TST-LITTLE CAESARS', 'Little Caesars'],
    ['TST*PIZZERIA', 'Pizzeria'],
    ['GOOGLE *YOUTUBE', 'Youtube'],
    ['FACEBK *META INC', 'Meta Inc'],
    ['PAYPAL *EBAY', 'Ebay'],
    ['ABC*1234-PIZZA HUT', 'Pizza Hut'],
    ['AMZN MKTPLC SHOP', 'Shop'],
    ['AMZN PURCHASES', 'Purchases'],

    // Phone-number suffixes (§6.4 step 2).
    ['STARBUCKS 416-555-1234', 'Starbucks'],
    ['STARBUCKS 4165551234', 'Starbucks'],

    // Province codes at end (§6.4 step 3).
    ['TIM HORTONS ON', 'Tim Hortons'],
    ['BEST BUY BC', 'Best Buy'],

    // Store numbers (§6.4 step 4).
    ['WALMART #1234', 'Walmart'],

    // Title-case + whitespace (§6.4 step 5).
    ['mcdonalds', 'Mcdonalds'],
  ];

  group('MerchantNormalizer.normalize', () {
    for (final c in cases) {
      test('"${c[0]}" → "${c[1]}"', () {
        expect(MerchantNormalizer.normalize(c[0]), c[1]);
      });
    }
  });

  test('processor prefix is case-insensitive', () {
    expect(MerchantNormalizer.normalize('sq *cafe'), 'Cafe');
    expect(MerchantNormalizer.normalize('paypal *shop'), 'Shop');
  });
}

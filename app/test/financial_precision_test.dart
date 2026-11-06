import 'package:flutter_test/flutter_test.dart';
import 'package:sbill_app/models/ledger_models.dart';

void main() {
  test('FX input is exact, preserves fractions and rejects invalid rates', () {
    final decimal = FxRateSpecModel.parse('JPY', 'CNY', '0.0525')!;
    expect(decimal.numerator, 21);
    expect(decimal.denominator, 400);
    expect(decimal.convertMinor(1000, 0, 2), 5250);
    final fraction = FxRateSpecModel.parse('KWD', 'JPY', '100000/211')!;
    expect(FxRateSpecModel.parse('KWD', 'JPY', fraction.inputText)!.toJson(),
        fraction.toJson());
    expect(fraction.convertMinor(1234, 3, 0), 585);
    for (final raw in ['', '0', '-1', 'NaN', '7e2', '1/0', '1/-2', '1.2.3']) {
      expect(FxRateSpecModel.parse('USD', 'CNY', raw), isNull, reason: raw);
    }
  });

  test('FX rounding matches Rust and cannot overflow native signed amounts',
      () {
    final rate = FxRateSpecModel.parse('JPY', 'CNY', '1/200')!;
    expect(rate.convertMinor(1, 0, 2), 1);
    expect(rate.convertMinor(-1, 0, 2), -1);
    final large = FxRateSpecModel.parse('USD', 'CNY', '7')!;
    expect(large.convertMinor(9000000000000000000, 2, 2), isNull);
  });

  test('money parsing rejects signed fractions, excess precision and overflow',
      () {
    expect(MoneyFormatter.parseMajorToMinor('1.-2', 2), isNull);
    expect(MoneyFormatter.parseMajorToMinor('+1', 2), isNull);
    expect(MoneyFormatter.parseMajorToMinor('1.1', 0), isNull);
    expect(MoneyFormatter.parseMajorToMinor('1.001', 2), isNull);
    expect(MoneyFormatter.parseMajorToMinor('92233720368547758.08', 2), isNull);
    expect(MoneyFormatter.parseMajorToMinor('92233720368547758.07', 2),
        9223372036854775807);
    expect(MoneyFormatter.parseMajorToMinor('1.234', 3), 1234);
    expect(MoneyFormatter.parseMajorToMinor('1000', 0), 1000);
    expect(MoneyFormatter.parseMajorToMinor('.25', 2), 25);
  });

  test('weighted preview uses full weights without overflow or clamping', () {
    final shares = MoneyFormatter.apportionByWeights(
        9000000000000000000, {'A': 2000000000, 'B': 2000000000});
    expect(shares, {'A': 4500000000000000000, 'B': 4500000000000000000});
  });
}

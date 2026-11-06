import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sbill_app/models/ledger_models.dart';
import 'package:sbill_app/ui/widgets/animated_amount_text.dart';

void main() {
  test('signed minimum formats without overflowing absolute value', () {
    expect(MoneyFormatter.formatMinor(-9223372036854775807 - 1, 'CNY'),
        '-¥92,233,720,368,547,758.08');
    expect(MoneyFormatter.parseMajorToMinor('1,23.00', 2), isNull);
    expect(MoneyFormatter.parseMajorToMinor('1,234.00', 2), 123400);
  });
  testWidgets('animation displays exact final integer beyond double precision',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: AnimatedAmountText(
            amountMinor: 9007199254740993, currency: 'CNY')));
    await tester.pumpAndSettle();
    expect(find.text('¥90,071,992,547,409.93'), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(
        home: AnimatedAmountText(
            amountMinor: 9007199254741093, currency: 'CNY')));
    await tester.pumpAndSettle();
    expect(find.text('¥90,071,992,547,410.93'), findsOneWidget);
  });
}

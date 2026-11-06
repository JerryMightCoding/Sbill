import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sbill_app/models/ledger_models.dart';
import 'package:sbill_app/state/ledger_controller.dart';
import 'package:sbill_app/ui/screens/expense_editor_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'JPY edit preserves exact FX and category is single-select/cancellable',
      (tester) async {
    final home = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('sbill_precision_')))!;
    final controller = LedgerController();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    try {
      await tester.runAsync(() async {
        await controller.initializeApp(
            overrideDbPath: '${home.path}/ledger.sqlite3');
        expect(
            await controller.createLedger(
                groupName: '精确金额', displayName: '本人', companions: ['伙伴']),
            isTrue);
        final snap = controller.snapshot!;
        expect(
            await controller.upsertExpense(
                expenseId: 'foreign',
                parentRevisionEventIds: [],
                currency: 'CNY',
                totalMinor: 5250,
                payers: [
                  PayerContributionModel(
                      participantId: snap.activeActorId,
                      amountMinor: 5250,
                      originalCurrency: 'JPY',
                      originalAmountMinor: 1000,
                      frozenFxRate:
                          FxRateSpecModel.parse('JPY', 'CNY', '0.0525'))
                ],
                splitRule: SplitRuleModel(
                    kind: SplitModeKind.equal,
                    equalParticipants:
                        snap.participants.map((p) => p.participantId).toList()),
                title: '日元付款',
                note: '',
                revisionReason: '创建',
                voided: false),
            isTrue);
      });
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Builder(
                  builder: (context) => TextButton(
                      onPressed: () => showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          builder: (_) => ExpenseEditorSheet(
                              controller: controller,
                              existingExpense:
                                  controller.snapshot!.expenses.single)),
                      child: const Text('编辑'))))));
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      final title = find.byWidgetPredicate((w) =>
          w is TextField && w.decoration?.hintText == '输入消费内容，如：河口湖温泉酒店');
      await tester.tap(find.text('🏨 酒店住宿'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('🍜 餐厅用餐'));
      await tester.pumpAndSettle();
      final hotel = tester.widget<ChoiceChip>(find.ancestor(
          of: find.text('🏨 酒店住宿'), matching: find.byType(ChoiceChip)));
      expect(hotel.selected, isFalse);
      expect(
          tester.widget<TextField>(title).controller!.text, '🍜 餐厅用餐 · 日元付款');
      await tester.tap(find.text('🍜 餐厅用餐'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(title).controller!.text, '日元付款');
      final originalAmount = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '实付 JPY');
      await tester.scrollUntilVisible(originalAmount, 200,
          scrollable: find.byType(Scrollable).first);
      expect(tester.widget<TextField>(originalAmount).controller!.text,
          '1,000'.replaceAll(',', ''));
      final rate = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '冻结汇率（1 原币）');
      expect(tester.widget<TextField>(rate).controller!.text, '21/400');
      final save = find.textContaining('保存账单 (');
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(save);
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (controller.snapshot!.expenses.single.history.length < 2) {
          if (DateTime.now().isAfter(deadline)) {
            throw StateError(controller.lastError ?? '保存未完成');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      final payer =
          controller.snapshot!.expenses.single.displayRevision.payers.single;
      expect(payer.originalAmountMinor, 1000);
      expect(payer.amountMinor, 5250);
      expect(payer.frozenFxRate!.denominator, 400);
      await tester.runAsync(() async {
        expect(
            await controller.setFxRate(
                baseCurrency: 'CNY',
                quoteCurrency: 'JPY',
                numerator: 20,
                denominator: 1),
            isTrue);
        expect(await controller.setSettlementCurrency('JPY'), isTrue);
      });
      expect(controller.snapshot!.settlementCurrency, 'JPY');
      expect(
          controller.snapshot!.settlementPreviews['MergedCurrencyMinTransfers']!
              .settlementCurrency,
          'JPY');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.runAsync(() => home.delete(recursive: true));
      await tester.binding.setSurfaceSize(null);
    }
  });
}

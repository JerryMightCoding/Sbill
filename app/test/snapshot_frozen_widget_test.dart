import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sbill_app/models/ledger_models.dart';
import 'package:sbill_app/state/ledger_controller.dart';
import 'package:sbill_app/ui/screens/settlement_center_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'Formal card displays frozen transfers, not a later local currency preview',
      (tester) async {
    final home = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('sbill_frozen_')))!;
    final controller = LedgerController();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    try {
      await tester.runAsync(() async {
        await controller.initializeApp(
            overrideDbPath: '${home.path}/ledger.sqlite3');
        await controller.createLedger(
            groupName: '冻结方案', displayName: '本人', companions: ['伙伴']);
        final snap = controller.snapshot!;
        expect(
            await controller.upsertExpense(
                expenseId: 'expense',
                parentRevisionEventIds: [],
                currency: 'CNY',
                totalMinor: 100,
                payers: [
                  PayerContributionModel(
                      participantId: snap.activeActorId, amountMinor: 100)
                ],
                splitRule: SplitRuleModel(
                    kind: SplitModeKind.equal,
                    equalParticipants:
                        snap.participants.map((p) => p.participantId).toList()),
                title: '账目',
                note: '',
                revisionReason: '创建',
                voided: false),
            isTrue);
        expect(
            await controller.proposeSettlement(
                mode: SettlementModeOption.byCurrencyPairwise),
            isTrue);
        expect(
            await controller.setFxRate(
                baseCurrency: 'CNY',
                quoteCurrency: 'JPY',
                numerator: 20,
                denominator: 1),
            isTrue);
        expect(await controller.setSettlementCurrency('JPY'), isTrue);
      });
      expect(controller.snapshot!.snapshots.single.coveredExpenseCount, 1);
      await tester.pumpWidget(MaterialApp(
          home:
              Scaffold(body: SettlementCenterScreen(controller: controller))));
      await tester.pumpAndSettle();
      final title = find.text('冻结方案：1 笔转账');
      await tester.scrollUntilVisible(title, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(title);
      await tester.pumpAndSettle();
      expect(find.text('¥0.50 CNY'), findsOneWidget);
      expect(find.textContaining('冻结币种：按各原币 · 账目 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.runAsync(() => home.delete(recursive: true));
      await tester.binding.setSurfaceSize(null);
    }
  });
}

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sbill_app/state/ledger_controller.dart';
import 'package:sbill_app/ui/screens/settlement_center_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Pending receipt visibly blocks formal settlement',
      (tester) async {
    final home = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('sbill_guard_')))!;
    final controller = LedgerController();
    try {
      await tester.runAsync(() async {
        await controller.initializeApp(
            overrideDbPath: '${home.path}/ledger.sqlite3');
        await controller.createLedger(
            groupName: '收付核对', displayName: '本人', companions: ['伙伴']);
        final snap = controller.snapshot!;
        expect(
            await controller.declareRepayment(
                payerId: snap.activeActorId,
                payeeId: snap.participants
                    .firstWhere((p) => p.participantId != snap.activeActorId)
                    .participantId,
                currency: 'CNY',
                amountMinor: 100,
                note: '待确认'),
            isTrue);
      });
      expect(controller.snapshot!.formalSettlementBlocker, isNotNull);
      await tester.pumpWidget(MaterialApp(
          home:
              Scaffold(body: SettlementCenterScreen(controller: controller))));
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('formal_settlement_button'));
      await tester.scrollUntilVisible(button, 200,
          scrollable: find.byType(Scrollable).first);
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(find.text('请先核对待处理事件与收付款'), findsOneWidget);
      expect(find.text('所有已确认账目已结清，无需转账'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.runAsync(() => home.delete(recursive: true));
    }
  });
}

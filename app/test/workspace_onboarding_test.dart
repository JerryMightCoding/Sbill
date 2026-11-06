import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sbill_app/main.dart';
import 'package:sbill_app/state/ledger_controller.dart';

Future<void> waitFor(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Native operation did not finish');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'Fresh install -> create own trip -> first expense -> ledger picker',
      (tester) async {
    final home = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('sbill_onboarding_')))!;
    final controller = LedgerController();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    try {
      await tester.runAsync(() => controller.initializeApp(
          overrideDbPath: '${home.path}/ledger.sqlite3'));
      expect(controller.isAppReady, isTrue, reason: controller.lastError);
      expect(controller.isNativeRustLoaded, isTrue);
      expect(controller.ledgers, isEmpty);
      expect(controller.snapshot, isNull);
      await tester.pumpWidget(SbillApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('每次出行，一本清楚的账'), findsOneWidget);
      expect(find.textContaining('温泉酒店两晚合住'), findsNothing);

      await tester.tap(find.text('创建出行账本'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, '出行账本名称'), '周末杭州游');
      await tester.enterText(
          find.widgetWithText(TextFormField, '大家怎么称呼你'), '小杰');
      await tester.enterText(
          find.widgetWithText(TextFormField, '同行伙伴（选填，每行一位）'), '小白');
      await tester.ensureVisible(find.text('创建并开始记账'));
      await tester.runAsync(() async {
        await tester.tap(find.text('创建并开始记账'));
        await waitFor(() => controller.snapshot != null);
      });
      await tester.pumpAndSettle();
      expect(controller.snapshot!.expenses, isEmpty);
      expect(controller.snapshot!.participants.length, 2);
      expect(
          controller.snapshot!.participants
              .where((p) => p.boundPublicKey != null)
              .length,
          1);
      expect(find.text('记第一笔'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('记第一笔'));
      await tester.pumpAndSettle();
      final title = find.byWidgetPredicate((w) =>
          w is TextField && w.decoration?.hintText == '输入消费内容，如：河口湖温泉酒店');
      final amount = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.hintText == '0.00');
      await tester.enterText(title, '出发前早餐');
      await tester.enterText(amount, '36.00');
      await tester.pumpAndSettle();
      final save = find.textContaining('保存账单 (');
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(save);
        await waitFor(() => controller.snapshot!.expenses.length == 1);
      });
      await tester.pumpAndSettle();
      expect(
          controller.snapshot!.expenses.single.displayRevision.title, '出发前早餐');
      expect(controller.snapshot!.expenses.single.displayRevision.totalMinor,
          3600);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('同步与伙伴'));
      await tester.pumpAndSettle();
      expect(find.text('只同步当前出行'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('切换账本'));
        await waitFor(() => controller.snapshot == null);
      });
      await tester.pumpAndSettle();
      expect(find.text('我的出行账本'), findsOneWidget);
      expect(find.text('周末杭州游'), findsOneWidget);
      await tester.runAsync(
          () => controller.selectLedger(controller.ledgers.single.groupId));
      await tester.pumpAndSettle();
      expect(controller.snapshot!.expenses.length, 1);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.runAsync(() => home.delete(recursive: true));
      await tester.binding.setSurfaceSize(null);
    }
  });
}

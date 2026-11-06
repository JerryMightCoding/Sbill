import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sbill_app/models/ledger_models.dart';
import 'package:sbill_app/models/expense_list_options.dart';
import 'package:sbill_app/state/ledger_controller.dart';
import 'package:sbill_app/ui/screens/group_home_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('ExpenseListOptions sorts, groups and intersects filters', () {
    const catalog = ExpenseCategoryModel.presetCategories;
    const dining = ExpenseCategoryModel(id: 'preset_dining', icon: '🍜', name: '餐厅用餐', isCustom: false);
    const hotel = ExpenseCategoryModel(id: 'preset_hotel', icon: '🏨', name: '酒店住宿', isCustom: false);
    UiExpenseViewModel exp(String id, String currency, int total, DateTime? time,
        ExpenseCategoryModel? category, List<String> payers, Map<String, int> shares,
        {bool legacy = false, String title = '账单'}) => UiExpenseViewModel(
      expenseId: id, creatorMemberId: 'A', hasConflict: false, isSettledInPriorCommit: false,
      activeRevisionEventId: 'ev_$id', conflictBranches: const [], history: const [],
      activeRevision: ExpenseRevisionModel(
        expenseId: id, parentRevisionEventIds: const [], currency: currency, totalMinor: total,
        payers: [for (final p in payers) PayerContributionModel(participantId: p, amountMinor: total ~/ payers.length)],
        splitRule: SplitRuleModel(kind: SplitModeKind.equal, equalParticipants: shares.keys.toList()),
        resolvedShares: shares, attributionMatrix: const {}, title: title, note: '',
        revisionReason: '', voided: false,
        details: legacy ? null : ExpenseDetailsModel(occurredAtMs: time?.toUtc().millisecondsSinceEpoch, category: category),
      ),
    );
    final list = [
      exp('old', 'CNY', 2000, DateTime(2026, 11, 1, 9), dining, ['A'], {'A': 1000, 'B': 1000}),
      exp('future', 'CNY', 5000, DateTime(2026, 12, 1, 18), hotel, ['B'], {'A': 2500, 'B': 2500}),
      exp('usd', 'USD', 5000, DateTime(2026, 11, 20, 12), hotel, ['B'], {'B': 5000}),
      exp('legacy', 'CNY', 3000, null, null, ['A'], {'A': 3000}, legacy: true, title: '🍜 餐厅用餐 · 旧账'),
    ];
    final byDate = const ExpenseListOptions().sections(list, catalog);
    expect(byDate.map((s) => s.label), [
      '2026-12-01 星期二', '2026-11-20 星期五', '2026-11-01 星期日', '未记录日期']);
    expect(byDate.map((s) => s.subtotalLabel((_) => 2)), [
      '小计 ¥50.00', '小计 \$50.00', '小计 ¥20.00', '小计 ¥30.00']);
    final byCategory = const ExpenseListOptions(grouping: ExpenseGrouping.category).sections(list, catalog);
    expect(byCategory.firstWhere((s) => s.label == '🏨 酒店住宿').subtotalLabel((_) => 2),
        '小计 ¥50.00 + \$50.00');
    final filtered = ExpenseListOptions(
      order: ExpenseOrder.smallest, grouping: ExpenseGrouping.category,
      from: DateTime(2026, 11, 1), until: DateTime(2026, 12, 31),
      categoryIds: {'preset_hotel'}, amountCurrency: 'CNY', minMinor: 4000, maxMinor: 6000,
      payerIds: {'B', 'C'}, bearerIds: {'A'},
    ).sections(list, catalog);
    expect(filtered.single.label, '🏨 酒店住宿');
    expect(filtered.single.expenses.map((e) => e.expenseId), ['future']);
    expect(const ExpenseListOptions(grouping: ExpenseGrouping.none, categoryIds: {'preset_dining'}).sections(list, catalog).single.expenses.map((e) => e.expenseId), ['old', 'legacy']);
  });

  testWidgets('Phone UI records a future expense, groups by weekday and filters', (tester) async {
    final home = (await tester.runAsync(() => Directory.systemTemp.createTemp('sbill_schedule_')))!;
    final controller = LedgerController();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    try {
      await tester.runAsync(() async {
        await controller.initializeApp(overrideDbPath: '${home.path}/ledger.sqlite3');
        await controller.createLedger(groupName: '未来行程', displayName: '我', companions: ['同伴']);
        final snap = controller.snapshot!;
        await controller.upsertExpense(
          expenseId: 'past', parentRevisionEventIds: const [], currency: 'CNY', totalMinor: 2000,
          payers: [PayerContributionModel(participantId: snap.activeActorId, amountMinor: 2000)],
          splitRule: SplitRuleModel(kind: SplitModeKind.equal, equalParticipants: [snap.activeActorId]),
          title: '过去门票', note: '', revisionReason: '创建', voided: false,
          details: ExpenseDetailsModel(occurredAtMs: DateTime(2026, 11, 1, 10).toUtc().millisecondsSinceEpoch),
        );
      });
      await tester.pumpWidget(MaterialApp(home: GroupHomeScreen(controller: controller)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('记一笔'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('🏨 酒店住宿'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pick_expense_date')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Switch to input'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '12/01/2026');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(1), '88');
      await tester.pumpAndSettle();
      final save = find.textContaining('保存账单 (');
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(save);
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (controller.snapshot!.expenses.length < 2) {
          if (DateTime.now().isAfter(deadline)) throw StateError(controller.lastError ?? '未保存');
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(find.text('2026-12-01 星期二 · 1 笔'), findsOneWidget);
      expect(find.text('小计 ¥88.00'), findsOneWidget);
      expect(find.text('2026-11-01 星期日 · 1 笔'), findsOneWidget);
      expect(find.text('小计 ¥20.00'), findsOneWidget);
      expect(tester.getTopLeft(find.text('🏨 酒店住宿')).dy, lessThan(tester.getTopLeft(find.text('过去门票')).dy));
      await tester.tap(find.byKey(const ValueKey('open_expense_options')));
      await tester.pumpAndSettle();
      final chip = find.widgetWithText(FilterChip, '🏨 酒店住宿');
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      final min = find.byKey(const ValueKey('expense_min_amount'));
      await tester.ensureVisible(min);
      await tester.enterText(min, '50');
      await tester.tap(find.byKey(const ValueKey('apply_expense_options')));
      await tester.pumpAndSettle();
      expect(find.text('🏨 酒店住宿'), findsOneWidget);
      expect(find.text('过去门票'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('clear_expense_options')));
      await tester.pumpAndSettle();
      expect(find.text('过去门票'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.runAsync(() => home.delete(recursive: true));
      await tester.binding.setSurfaceSize(null);
    }
  });
}

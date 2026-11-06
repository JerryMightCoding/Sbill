import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sbill_app/models/ledger_models.dart';
import 'package:sbill_app/state/ledger_controller.dart';

void main() {
  test('M4 closed-loop workflow: init, multi-payer bill, conflict resolve, repayment dual-confirm', () async {
    final controller = LedgerController();
    await controller.initialize();

    expect(controller.snapshot, isNotNull);
    expect(controller.snapshot!.expenses.length, 2);
    expect(controller.snapshot!.conflictCount, 0);

    // 1. Verify exact integer formatting and Largest-Remainder split preview
    expect(MoneyFormatter.parseMajorToMinor('125.50', 2), 12550);
    final split3 = MoneyFormatter.apportionByWeights(100, {'A': 1, 'B': 1, 'C': 1});
    expect(split3, {'A': 34, 'B': 33, 'C': 33});

    // 2. Simulate concurrent offline edits on exp_hotel_cny -> creates 2 conflict branches
    final simOk = await controller.simulateConcurrentConflict('exp_hotel_cny');
    expect(simOk, isTrue);
    expect(controller.snapshot!.conflictCount, 1);
    final conflicted = controller.snapshot!.expenses
        .firstWhere((e) => e.expenseId == 'exp_hotel_cny');
    expect(conflicted.hasConflict, isTrue);
    expect(conflicted.conflictBranches.length, 2);

    // 3. Switch to FinanceEditor B and resolve the conflict by referencing both branch event IDs
    await controller.switchActor('B');
    final parentIds =
        conflicted.conflictBranches.map((b) => b.eventId).toList();
    final resolveOk = await controller.upsertExpense(
      expenseId: 'exp_hotel_cny',
      parentRevisionEventIds: parentIds,
      currency: 'CNY',
      totalMinor: 112000,
      payers: const [
        PayerContributionModel(participantId: 'A', amountMinor: 72000),
        PayerContributionModel(participantId: 'B', amountMinor: 40000),
      ],
      splitRule: const SplitRuleModel(
        kind: SplitModeKind.equal,
        equalParticipants: ['A', 'B', 'C', 'D'],
      ),
      title: '温泉酒店两晚合住 (已合并解决)',
      note: '管理员白露核对确认',
      revisionReason: '合并创建人与管理员离线分支',
      voided: false,
    );
    expect(resolveOk, isTrue);
    expect(controller.snapshot!.conflictCount, 0);

    // 4. Repayment declare by D -> only payee A can confirm receipt
    await controller.switchActor('D');
    final declOk = await controller.declareRepayment(
      payerId: 'D',
      payeeId: 'A',
      currency: 'CNY',
      amountMinor: 15000,
      note: 'D向A还款150元',
    );
    expect(declOk, isTrue);
    final rep = controller.snapshot!.repayments.first;
    expect(rep.isConfirmed, isFalse);

    // Non-payee D attempting to confirm must fail
    final badConfirm = await controller.confirmRepayment(
      paymentId: rep.paymentId,
      declareEventId: rep.declareEventId,
    );
    expect(badConfirm, isFalse);
    expect(controller.lastError, isNotNull);

    // Switch to payee A and confirm receipt
    await controller.switchActor('A');
    final goodConfirm = await controller.confirmRepayment(
      paymentId: rep.paymentId,
      declareEventId: rep.declareEventId,
    );
    expect(goodConfirm, isTrue);
    expect(controller.snapshot!.repayments.first.isConfirmed, isTrue);
  });

  test('SQLite disk persistence across controller restart', () async {
    final tempDir = await Directory.systemTemp.createTemp('sbill_flutter_persist_');
    final dbPath = '${tempDir.path}/sbill_ledger_v1.sqlite3';

    try {
      // First session: open persistent DB and add a 3rd bill
      final c1 = LedgerController();
      await c1.initialize(overrideDbPath: dbPath);
      expect(c1.isNativeRustLoaded, isTrue);
      expect(c1.snapshot!.expenses.length, 2);

      final added = await c1.upsertExpense(
        expenseId: 'exp_disk_persist_01',
        parentRevisionEventIds: const [],
        currency: 'CNY',
        totalMinor: 26000,
        payers: const [
          PayerContributionModel(participantId: 'A', amountMinor: 26000),
        ],
        splitRule: const SplitRuleModel(
          kind: SplitModeKind.equal,
          equalParticipants: ['A', 'B', 'C', 'D'],
        ),
        title: '持久化测试账单 (缆车票)',
        note: '杀掉进程重启后依然保留',
        revisionReason: '创建账单',
        voided: false,
      );
      expect(added, isTrue);
      expect(c1.snapshot!.expenses.length, 3);

      // Add a custom category with Emoji icon and verify it persists across restart
      final catOk = await c1.addCustomCategory(icon: '🎿', name: '滑雪装备');
      expect(catOk, isTrue);
      expect(
        c1.snapshot!.customCategories.any((c) => c.icon == '🎿' && c.name == '滑雪装备'),
        isTrue,
      );

      // Simulate switching to another DB and then reopening `dbPath` on restart
      final cOther = LedgerController();
      await cOther.initialize(overrideDbPath: '${tempDir.path}/other.sqlite3');
      expect(cOther.snapshot!.expenses.length, 2);

      final cRestarted = LedgerController();
      await cRestarted.initialize(overrideDbPath: dbPath);
      expect(cRestarted.snapshot!.expenses.length, 3);
      expect(
        cRestarted.snapshot!.expenses.any((e) => e.expenseId == 'exp_disk_persist_01'),
        isTrue,
      );
      expect(
        cRestarted.snapshot!.customCategories
            .any((c) => c.icon == '🎿' && c.name == '滑雪装备'),
        isTrue,
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });
}

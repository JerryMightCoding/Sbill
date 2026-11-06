import 'package:flutter_test/flutter_test.dart';
import 'package:sbill_app/models/ledger_models.dart';
import 'package:sbill_app/state/ledger_controller.dart';

void main() {
  test('M5 Settlement Center: 4 modes preview, snapshot proposal, multi-party approval & debt novation', () async {
    final controller = LedgerController();
    await controller.resetDemoWorkspace();

    final snap0 = controller.snapshot!;
    expect(
      snap0.settlementPreviews['ByCurrencyPairwise']!.transfers.length,
      8,
    );
    expect(
      snap0.settlementPreviews['ByCurrencyMinTransfers']!.transfers.length,
      6,
    );
    expect(
      snap0.settlementPreviews['MergedCurrencyPairwise']!.transfers.length,
      6,
    );
    expect(
      snap0.settlementPreviews['MergedCurrencyMinTransfers']!.transfers.length,
      3,
    );

    // 1. Propose formal settlement snapshot in MergedCurrencyMinTransfers mode
    final propOk = await controller.proposeSettlement(
      mode: SettlementModeOption.mergedCurrencyMinTransfers,
      settlementCurrency: 'CNY',
    );
    expect(propOk, isTrue);
    final proposed = controller.snapshot!.snapshots.first;
    expect(proposed.isCommitted, isFalse);

    // 2. Premature commit before all required approvers sign must fail (AC-S07)
    final prematureCommit =
        await controller.commitSettlement(proposed.snapshotId);
    expect(prematureCommit, isFalse);

    // 3. Approve across all 4 affected participants (A, B, C, D)
    for (final pid in ['A', 'B', 'C', 'D']) {
      await controller.switchActor(pid);
      final appOk = await controller.approveSettlement(proposed.snapshotId);
      expect(appOk, isTrue, reason: '$pid: ${controller.lastError}');
    }

    // 4. Switch to coordinator A and commit snapshot -> Debt Novation creates 3 obligations
    await controller.switchActor('A');
    final commitOk = await controller.commitSettlement(proposed.snapshotId);
    expect(commitOk, isTrue);
    expect(controller.snapshot!.activeObligations.length, 3);

    // 5. Pay and confirm each novated obligation
    final obligations = List<SettlementObligationModel>.from(
      controller.snapshot!.activeObligations,
    );
    for (final ob in obligations) {
      await controller.switchActor(ob.debtorId);
      final declOk = await controller.declareRepayment(
        payerId: ob.debtorId,
        payeeId: ob.creditorId,
        currency: ob.currency,
        amountMinor: ob.remainingMinor,
        targetObligationId: ob.obligationId,
        note: '结清重组义务 ${ob.obligationId}',
      );
      expect(declOk, isTrue);

      final latestRep = controller.snapshot!.repayments.last;
      await controller.switchActor(ob.creditorId);
      final confOk = await controller.confirmRepayment(
        paymentId: latestRep.paymentId,
        declareEventId: latestRep.declareEventId,
      );
      expect(confOk, isTrue);
    }

    // 6. Verify all 4 modes show 0 remaining transfers (no resurrected old debts, AC-S08/AC-S09)
    for (final preview in controller.snapshot!.settlementPreviews.values) {
      expect(preview.transfers, isEmpty);
    }
  });
}

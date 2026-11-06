import 'package:flutter/material.dart';

import '../../models/ledger_models.dart';
import '../../state/ledger_controller.dart';
import '../theme/app_theme.dart';
import 'expense_editor_sheet.dart';

/// M4 Conflict Resolution Screen (FR-CON-01, AC-C01, AC-C02).
/// Displays all concurrent revision branches side-by-side / stacked with highlighted diffs,
/// allowing an authorized FinanceEditor or Owner to adopt a branch or customize a merged revision
/// that references all conflicting parent revision IDs.
class ConflictResolutionScreen extends StatelessWidget {
  const ConflictResolutionScreen({
    super.key,
    required this.controller,
    required this.expenseId,
  });

  final LedgerController controller;
  final String expenseId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final snap = controller.snapshot!;
        final expense = snap.expenses.firstWhere(
          (e) => e.expenseId == expenseId,
        );
        final canResolve = snap.activeActor.role.canEditAnyBill;
        final parentIds =
            expense.conflictBranches.map((b) => b.eventId).toList();

        return Scaffold(
          appBar: AppBar(
            title: const Text('解决并发修订冲突'),
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.conflictAmber.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: AppTheme.conflictAmber.withValues(alpha: 0.4),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          color: AppTheme.conflictAmber,
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '检测到多端离线并发修改分支',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                              color: AppTheme.deepSlate,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '系统未静默覆盖任何一方的金额，也未逐字段拼凑未验证账单。请核对以下 ${expense.conflictBranches.length} 个并发分支，由群主或财务管理员提交合并版本（同时引用双方父版本 ID）。',
                      style: const TextStyle(fontSize: 13, height: 1.4),
                    ),
                    if (!canResolve) ...[
                      const SizedBox(height: 8),
                      Text(
                        '当前视角为 ${snap.activeActor.displayName} (${snap.activeActor.role.label})，请切换到群主或财务管理员视角执行冲突合并。',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.debtRose,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              ...expense.conflictBranches.asMap().entries.map((entry) {
                final idx = entry.key;
                final branch = entry.value;
                final rev = branch.payload;
                final decimals = snap.decimalsOf(rev.currency);
                return Card(
                  margin: const EdgeInsets.only(bottom: 14),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: AppTheme.conflictAmber
                                    .withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '并发分支 #${idx + 1}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.conflictAmber,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '提交人: ${snap.nameOf(branch.authorMemberId)} (${branch.deviceId} · seq ${branch.sequence})',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.blueGrey,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                rev.title,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Text(
                              MoneyFormatter.formatMinor(
                                rev.totalMinor,
                                rev.currency,
                                decimals: decimals,
                              ),
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.primaryTeal,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '修改原因: ${rev.revisionReason}',
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: rev.payers.map((p) {
                            return Chip(
                              visualDensity: VisualDensity.compact,
                              label: Text(
                                '${snap.nameOf(p.participantId)} 垫付 ${MoneyFormatter.formatMinor(p.amountMinor, rev.currency, decimals: decimals)}',
                                style: const TextStyle(fontSize: 12),
                              ),
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            OutlinedButton.icon(
                              onPressed: canResolve
                                  ? () async {
                                      await showModalBottomSheet<bool>(
                                        context: context,
                                        isScrollControlled: true,
                                        backgroundColor: Colors.transparent,
                                        builder: (_) => ExpenseEditorSheet(
                                          controller: controller,
                                          existingExpense: expense,
                                          overrideParentRevisionIds: parentIds,
                                          initialDraft: rev,
                                        ),
                                      );
                                      if (context.mounted &&
                                          !controller.snapshot!.expenses
                                              .firstWhere((e) =>
                                                  e.expenseId == expenseId)
                                              .hasConflict) {
                                        Navigator.of(context).pop();
                                      }
                                    }
                                  : null,
                              icon: const Icon(Icons.tune, size: 16),
                              label: const Text('以此为基础微调合并'),
                            ),
                            const SizedBox(width: 10),
                            FilledButton.icon(
                              onPressed: canResolve
                                  ? () async {
                                      final ok = await controller.upsertExpense(
                                        expenseId: expense.expenseId,
                                        parentRevisionEventIds: parentIds,
                                        currency: rev.currency,
                                        totalMinor: rev.totalMinor,
                                        payers: rev.payers,
                                        splitRule: rev.splitRule,
                                        title: rev.title
                                            .replaceAll(' (创建人离线改)', '')
                                            .replaceAll(' (管理员离线改)', ''),
                                        note: rev.note,
                                        revisionReason:
                                            '采纳分支 #${idx + 1} (${snap.nameOf(branch.authorMemberId)}) 解决并发冲突',
                                        voided: rev.voided,
                                        details: rev.details ?? const ExpenseDetailsModel(),
                                      );
                                      if (ok && context.mounted) {
                                        Navigator.of(context).pop();
                                      }
                                    }
                                  : null,
                              icon: const Icon(Icons.check_circle_outline, size: 16),
                              label: const Text('采纳此分支合并'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }
}

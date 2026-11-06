import 'package:flutter/material.dart';

import '../../models/ledger_models.dart';
import '../../models/expense_list_options.dart';
import '../../state/ledger_controller.dart';
import '../theme/app_theme.dart';
import 'conflict_resolution_screen.dart';
import 'expense_editor_sheet.dart';

/// M4 Expense Detail Screen displaying:
/// - Active revision payers, resolved participant shares, and pairwise debt attribution matrix
/// - Complete immutable revision history timeline (creator V1 -> admin V2 edits -> conflict merges)
/// - Role-checked edit, void, and 1-tap concurrent conflict simulation
class ExpenseDetailScreen extends StatelessWidget {
  const ExpenseDetailScreen({
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
        final rev = expense.displayRevision;
        final decimals = snap.decimalsOf(rev.currency);
        final actor = snap.activeActor;
        final canEdit = actor.active &&
            actor.role != MemberRole.viewer &&
            (actor.participantId == expense.creatorMemberId ||
                actor.role.canEditAnyBill);

        return Scaffold(
          appBar: AppBar(
            title: const Text('账单详情与修订审计'),
            actions: [
              if (!controller.isAppMode && !expense.hasConflict)
                TextButton.icon(
                  onPressed: () async {
                    await controller.simulateConcurrentConflict(expenseId);
                  },
                  icon: const Icon(
                    Icons.call_split,
                    size: 18,
                    color: AppTheme.conflictAmber,
                  ),
                  label: const Text(
                    '模拟离线并发冲突',
                    style: TextStyle(color: AppTheme.conflictAmber),
                  ),
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (expense.hasConflict)
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppTheme.conflictAmber.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: AppTheme.conflictAmber.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: AppTheme.conflictAmber,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '该账单存在 ${expense.conflictBranches.length} 个未解决的并发修订分支，暂停计入正式结算。',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      FilledButton.tonal(
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ConflictResolutionScreen(
                                controller: controller,
                                expenseId: expenseId,
                              ),
                            ),
                          );
                        },
                        child: const Text('去解决'),
                      ),
                    ],
                  ),
                ),

              // 1. 账单头部卡片
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color:
                                  AppTheme.primaryTeal.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '${rev.currency} · V${expense.history.length}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.primaryTeal,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '初始创建人: ${snap.nameOf(expense.creatorMemberId)}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.blueGrey,
                            ),
                          ),
                          const Spacer(),
                          if (rev.voided)
                            const Chip(
                              label: Text('已作废'),
                              backgroundColor: Color(0xFFFEE2E2),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        rev.title,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          decoration:
                              rev.voided ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        MoneyFormatter.formatMinor(
                          rev.totalMinor,
                          rev.currency,
                          decimals: decimals,
                        ),
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                          color: AppTheme.primaryTeal,
                        ),
                      ),
                      if (rev.details?.localTime != null || expenseCategoryOf(rev, snap.allCategories) != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text([
                            if (rev.details?.localTime != null)
                              '${expenseDateLabel(rev.details!.localTime!)} ${expenseTimeLabel(rev.details!.localTime!)}',
                            if (expenseCategoryOf(rev, snap.allCategories) != null)
                              '${expenseCategoryOf(rev, snap.allCategories)!.icon} ${expenseCategoryOf(rev, snap.allCategories)!.name}',
                          ].join(' · '), style: const TextStyle(fontSize: 12, color: Colors.blueGrey)),
                        ),
                      if (rev.note.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          rev.note,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.black54,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // 2. 垫付明细与承担明细
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '垫付人明细',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...rev.payers.map((p) {
                        final hasForeign = p.originalCurrency != null &&
                            p.originalAmountMinor != null;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(snap.nameOf(p.participantId)),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    MoneyFormatter.formatMinor(
                                      p.amountMinor,
                                      rev.currency,
                                      decimals: decimals,
                                    ),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.creditEmerald,
                                    ),
                                  ),
                                  if (hasForeign)
                                    Text(
                                      '实付 ${MoneyFormatter.formatMinor(p.originalAmountMinor!, p.originalCurrency!, decimals: snap.decimalsOf(p.originalCurrency!))} (冻结汇率 ${p.frozenFxRate?.numerator}/${p.frozenFxRate?.denominator})',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.blueGrey,
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        );
                      }),
                      const Divider(height: 24),
                      Text(
                        '消费承担明细 (${rev.splitRule.kind.label})',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...rev.resolvedShares.entries.map((e) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(snap.nameOf(e.key)),
                              Text(
                                MoneyFormatter.formatMinor(
                                  e.value,
                                  rev.currency,
                                  decimals: decimals,
                                ),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // 3. 单笔账单债权归因矩阵
              if (rev.attributionMatrix.isNotEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '本单债权归因矩阵 (按垫付占比二维守恒分配)',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ...rev.attributionMatrix.entries.expand((debtorEntry) {
                          return debtorEntry.value.entries.map((credEntry) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Row(
                                children: [
                                  Text(
                                    snap.nameOf(debtorEntry.key),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const Padding(
                                    padding:
                                        EdgeInsets.symmetric(horizontal: 8),
                                    child: Icon(
                                      Icons.arrow_forward,
                                      size: 15,
                                      color: Colors.grey,
                                    ),
                                  ),
                                  Text(
                                    snap.nameOf(credEntry.key),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    MoneyFormatter.formatMinor(
                                      credEntry.value,
                                      rev.currency,
                                      decimals: decimals,
                                    ),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          });
                        }),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 14),

              // 4. 不可变签名修订历史时间轴 (AC-A01)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '签名修订历史 (追加式审计链，不可篡改原记录)',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 12),
                      ...expense.history.asMap().entries.map((entry) {
                        final idx = entry.key;
                        final item = entry.value;
                        final itemDec = snap.decimalsOf(item.payload.currency);
                        final isActive =
                            item.eventId == expense.activeRevisionEventId;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isActive
                                ? AppTheme.primaryTeal.withValues(alpha: 0.06)
                                : Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isActive
                                  ? AppTheme.primaryTeal.withValues(alpha: 0.4)
                                  : Colors.grey.shade200,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    'V${idx + 1} · ${snap.nameOf(item.authorMemberId)}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '(${item.deviceId}#${item.sequence})',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.blueGrey,
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    MoneyFormatter.formatMinor(
                                      item.payload.totalMinor,
                                      item.payload.currency,
                                      decimals: itemDec,
                                    ),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '原因: ${item.payload.revisionReason}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.black87,
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
            ],
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  if (!canEdit)
                    Expanded(
                      child: Text(
                        '当前视角 (${actor.displayName}) 不是创建人且无财务管理员权限，不可修改他人账单',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.debtRose,
                        ),
                      ),
                    )
                  else ...[
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: rev.voided || expense.hasConflict
                            ? null
                            : () async {
                                await controller.upsertExpense(
                                  expenseId: expense.expenseId,
                                  parentRevisionEventIds: [
                                    expense.activeRevisionEventId!,
                                  ],
                                  currency: rev.currency,
                                  totalMinor: 0,
                                  payers: const [],
                                  splitRule: rev.splitRule,
                                  title: rev.title,
                                  note: rev.note,
                                  revisionReason: '${actor.displayName} 作废账单',
                                  voided: true,
                                  details: rev.details,
                                );
                              },
                        icon: const Icon(Icons.block, size: 18),
                        label: const Text('作废账单'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: expense.hasConflict
                            ? null
                            : () {
                                showModalBottomSheet<bool>(
                                  context: context,
                                  isScrollControlled: true,
                                  backgroundColor: Colors.transparent,
                                  builder: (_) => ExpenseEditorSheet(
                                    controller: controller,
                                    existingExpense: expense,
                                  ),
                                );
                              },
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        label: Text(
                          actor.participantId == expense.creatorMemberId
                              ? '修改我的账单'
                              : '管理员修订账单',
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

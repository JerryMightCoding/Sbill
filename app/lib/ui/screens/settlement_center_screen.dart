import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/ledger_models.dart';
import '../../state/ledger_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/animated_amount_text.dart';

/// Unified Settlement & Repayments View:
/// Combines the 4-mode settlement calculator, 1-tap "Mark as Paid" actions,
/// formal snapshot multi-party signing, and dual-confirmed repayment stream in one cohesive flow.
class SettlementCenterScreen extends StatefulWidget {
  const SettlementCenterScreen({
    super.key,
    required this.controller,
  });

  final LedgerController controller;

  @override
  State<SettlementCenterScreen> createState() => _SettlementCenterScreenState();
}

class _SettlementCenterScreenState extends State<SettlementCenterScreen> {
  bool _mergeCurrency = true;
  bool _simplifyTransfers = true;

  SettlementModeOption get _selectedMode => SettlementModeOption.fromSwitches(
        mergeCurrency: _mergeCurrency,
        simplifyTransfers: _simplifyTransfers,
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final snap = widget.controller.snapshot;
        if (snap == null) {
          return const Center(child: CircularProgressIndicator());
        }

        final mode = _selectedMode;
        final preview = snap.settlementPreviews[mode.wireName];
        final actor = snap.activeActor;

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            // 1. 待收款方确认横幅（最优先提醒收款人确认）
            if (snap.repayments.isNotEmpty) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.payments_outlined,
                            size: 18,
                            color: AppTheme.primaryTeal,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '收付确认记录 (${snap.repayments.length})',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                            ),
                          ),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: () =>
                                _showCustomRepaymentDialog(context, snap),
                            icon: const Icon(Icons.add, size: 16),
                            label: const Text('记一笔还款'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ...snap.repayments.map((rep) {
                        final dec = snap.decimalsOf(rep.currency);
                        final isPayeeViewing =
                            snap.activeActorId == rep.payeeId;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: rep.isConfirmed
                                ? AppTheme.creditEmerald.withValues(alpha: 0.06)
                                : AppTheme.conflictAmber
                                    .withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${snap.nameOf(rep.payerId)} → ${snap.nameOf(rep.payeeId)} · ${MoneyFormatter.formatMinor(rep.amountMinor, rep.currency, decimals: dec)}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 14,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      rep.statusLabel,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: rep.isConfirmed
                                            ? AppTheme.creditEmerald
                                            : AppTheme.conflictAmber,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (!rep.isConfirmed &&
                                  !rep.isPendingMapping &&
                                  isPayeeViewing &&
                                  actor.active)
                                Wrap(
                                  spacing: 6,
                                  children: [
                                    if (!rep.isDisputed)
                                      OutlinedButton(
                                        key: ValueKey(
                                            'dispute_repayment_${rep.paymentId}'),
                                        onPressed: () =>
                                            _showDisputeRepaymentDialog(
                                                context, rep),
                                        child: const Text('异议'),
                                      ),
                                    FilledButton.tonalIcon(
                                      key: ValueKey(
                                          'confirm_repayment_${rep.paymentId}'),
                                      onPressed: () {
                                        HapticFeedback.lightImpact();
                                        widget.controller.confirmRepayment(
                                          paymentId: rep.paymentId,
                                          declareEventId: rep.declareEventId,
                                        );
                                      },
                                      icon: const Icon(Icons.check, size: 16),
                                      label: const Text('确认收款'),
                                    ),
                                  ],
                                ),
                              if (rep.isPendingMapping && actor.active)
                                OutlinedButton.icon(
                                  key: ValueKey(
                                      'map_late_repayment_${rep.paymentId}'),
                                  onPressed: () =>
                                      _showMapLateRepaymentDialog(
                                          context, snap, rep),
                                  icon: const Icon(Icons.link, size: 16),
                                  label: const Text('映射义务'),
                                ),
                              if (!rep.isConfirmed &&
                                  !rep.isPendingMapping &&
                                  !isPayeeViewing)
                                Text(
                                  rep.isDisputed
                                      ? '需核对后确认'
                                      : '待 ${snap.nameOf(rep.payeeId)} 确认',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: AppTheme.mutedSlate,
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
            ],

            // 2. 四种结算模式双开关控制台
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '结算方案试算',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () => _showFxRateDialog(context, snap),
                          icon: const Icon(Icons.currency_exchange, size: 16),
                          label: const Text('结算汇率'),
                        ),
                      ],
                    ),
                    if (snap.defaultFxRates.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: snap.defaultFxRates
                              .take(2)
                              .map(
                                (r) => Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppTheme.surfaceBg,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    r.displayRatio,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: AppTheme.mutedSlate,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '合并币种结算 (统一折算为 ${snap.settlementCurrency})',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      subtitle: Text(
                        _mergeCurrency
                            ? '将多币种账单按冻结汇率折算后统一对冲'
                            : '各币种分别结算，不跨币种抵消',
                        style: const TextStyle(fontSize: 12),
                      ),
                      value: _mergeCurrency,
                      onChanged: (v) {
                        HapticFeedback.selectionClick();
                        setState(() => _mergeCurrency = v);
                      },
                    ),
                    if (_mergeCurrency)
                      DropdownButtonFormField<String>(
                        initialValue: snap.settlementCurrency,
                        decoration:
                            const InputDecoration(labelText: '本地试算结算币种'),
                        items: snap.currencies.keys
                            .map((c) =>
                                DropdownMenuItem(value: c, child: Text(c)))
                            .toList(),
                        onChanged: (currency) {
                          if (currency != null) {
                            widget.controller.setSettlementCurrency(currency);
                          }
                        },
                      ),
                    const Divider(height: 8),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        '最少转账次数优化',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      subtitle: Text(
                        _simplifyTransfers
                            ? '按全组净余额重排，减少转账总笔数'
                            : '保留每笔账单的原始一对一欠款关系',
                        style: const TextStyle(fontSize: 12),
                      ),
                      value: _simplifyTransfers,
                      onChanged: (v) {
                        HapticFeedback.selectionClick();
                        setState(() => _simplifyTransfers = v);
                      },
                    ),
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: SettlementModeOption.values.map((opt) {
                          final count = snap.settlementPreviews[opt.wireName]
                                  ?.transfers.length ??
                              0;
                          final isSelected = opt == mode;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              selected: isSelected,
                              onSelected: (_) {
                                HapticFeedback.selectionClick();
                                setState(() {
                                  _mergeCurrency = opt.mergeCurrency;
                                  _simplifyTransfers = opt.simplifyTransfers;
                                });
                              },
                              label: Text(
                                '${opt.label} ($count笔)',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: isSelected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),

            // 3. 当前方案转账清单 + 一键记已还
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            mode.label,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        if (preview != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.creditEmerald
                                  .withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              mode.simplifyTransfers
                                  ? (preview.provenOptimal
                                      ? '已证明最少笔数'
                                      : '启发式优化方案')
                                  : '一对一原始关系',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.creditEmerald,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    AnimatedSwitcher(
                      duration: AppTheme.mediumAnim,
                      switchInCurve: AppTheme.smoothCurve,
                      child: preview == null
                          ? const Padding(
                              key: ValueKey('preview_unavailable'),
                              padding: EdgeInsets.all(20),
                              child: Text(
                                  '当前模式暂不能计算。请补充结算汇率，或切换为按币种结算；这不代表账目已结清。',
                                  style: TextStyle(
                                      color: AppTheme.conflictAmber,
                                      height: 1.6)),
                            )
                          : preview.transfers.isEmpty
                              ? Container(
                                  key: const ValueKey('settled_empty'),
                                  padding: const EdgeInsets.all(22),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: AppTheme.creditEmerald
                                        .withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.verified_rounded,
                                          color: AppTheme.creditEmerald),
                                      const SizedBox(width: 8),
                                      Expanded(
                                          child: Text(
                                        snap.formalSettlementBlocker != null
                                            ? '当前无需转账，仍有收付或事件待核对'
                                            : (snap
                                                        .settlementPreviews[
                                                            'ByCurrencyPairwise']
                                                        ?.transfers
                                                        .isNotEmpty ??
                                                    false)
                                                ? '本方案可抵销欠款；须共同确认后正式生效'
                                                : '所有已确认账目已结清，无需转账',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            color: AppTheme.creditEmerald),
                                      )),
                                    ],
                                  ),
                                )
                              : Column(
                                  key: ValueKey(
                                    '${mode.wireName}_${preview.transfers.length}',
                                  ),
                                  children: preview.transfers.map((tr) {
                                    final dec = snap.decimalsOf(tr.currency);
                                    final isMeDebtor =
                                        tr.debtorId == actor.participantId;
                                    final isMeCreditor =
                                        tr.creditorId == actor.participantId;
                                    return Container(
                                      margin: const EdgeInsets.only(bottom: 10),
                                      padding: const EdgeInsets.all(14),
                                      decoration: BoxDecoration(
                                        color: (isMeDebtor || isMeCreditor)
                                            ? AppTheme.primaryTeal
                                                .withValues(alpha: 0.05)
                                            : AppTheme.surfaceBg,
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(
                                          color: (isMeDebtor || isMeCreditor)
                                              ? AppTheme.primaryTeal
                                                  .withValues(alpha: 0.3)
                                              : Colors.transparent,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Text(
                                                      snap.nameOf(tr.debtorId),
                                                      style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                    ),
                                                    const Padding(
                                                      padding:
                                                          EdgeInsets.symmetric(
                                                        horizontal: 6,
                                                      ),
                                                      child: Icon(
                                                        Icons.east_rounded,
                                                        size: 15,
                                                        color: AppTheme
                                                            .primaryTeal,
                                                      ),
                                                    ),
                                                    Expanded(
                                                      child: Text(
                                                        snap.nameOf(
                                                            tr.creditorId),
                                                        style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.w700,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 4),
                                                AnimatedAmountText(
                                                  amountMinor: tr.amountMinor,
                                                  currency: tr.currency,
                                                  decimals: dec,
                                                  style: const TextStyle(
                                                    fontSize: 18,
                                                    fontWeight: FontWeight.w900,
                                                    color: AppTheme.primaryTeal,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          OutlinedButton(
                                            onPressed: actor.active &&
                                                    actor.role !=
                                                        MemberRole.viewer &&
                                                    actor.participantId ==
                                                        tr.debtorId &&
                                                    !mode.simplifyTransfers &&
                                                    !mode.mergeCurrency
                                                ? () {
                                                    HapticFeedback
                                                        .lightImpact();
                                                    widget.controller
                                                        .declareRepayment(
                                                      payerId: tr.debtorId,
                                                      payeeId: tr.creditorId,
                                                      currency: tr.currency,
                                                      amountMinor:
                                                          tr.amountMinor,
                                                      note:
                                                          '按${mode.label}方案转账',
                                                    );
                                                  }
                                                : null,
                                            child: const Text('记已还'),
                                          ),
                                        ],
                                      ),
                                    );
                                  }).toList(),
                                ),
                    ),
                    const SizedBox(height: 8),
                    if (snap.formalSettlementBlocker != null)
                      Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(snap.formalSettlementBlocker!,
                              style: const TextStyle(
                                  color: AppTheme.conflictAmber))),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const ValueKey('formal_settlement_button'),
                        onPressed: actor.active &&
                                actor.role.canPublishSettlement &&
                                snap.formalSettlementBlocker == null &&
                                preview != null &&
                                (snap.settlementPreviews['ByCurrencyPairwise']
                                        ?.transfers.isNotEmpty ??
                                    false)
                            ? () {
                                HapticFeedback.lightImpact();
                                widget.controller.proposeSettlement(
                                  mode: mode,
                                  settlementCurrency: mode.mergeCurrency
                                      ? snap.settlementCurrency
                                      : null,
                                );
                              }
                            : null,
                        icon: const Icon(Icons.lock_outline_rounded, size: 18),
                        label: Text(
                          snap.formalSettlementBlocker != null
                              ? '请先核对待处理事件与收付款'
                              : '发布正式结算快照供大家确认',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // 4. 已正式提交的重组结算义务 (Debt Novation)
            if (snap.activeObligations.isNotEmpty) ...[
              const SizedBox(height: 14),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '已共同确认的正式结算义务',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 10),
                      ...snap.activeObligations.map((ob) {
                        final dec = snap.decimalsOf(ob.currency);
                        final rem = ob.remainingMinor;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: ob.isFullyPaid
                                ? AppTheme.creditEmerald.withValues(alpha: 0.06)
                                : AppTheme.surfaceBg,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${snap.nameOf(ob.debtorId)} → ${snap.nameOf(ob.creditorId)}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    Text(
                                      ob.isFullyPaid
                                          ? '已结清'
                                          : '待还 ${MoneyFormatter.formatMinor(rem, ob.currency, decimals: dec)}',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w800,
                                        color: ob.isFullyPaid
                                            ? AppTheme.creditEmerald
                                            : AppTheme.debtRose,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (!ob.isFullyPaid &&
                                  actor.active &&
                                  actor.participantId == ob.debtorId)
                                FilledButton.tonal(
                                  onPressed: () {
                                    HapticFeedback.lightImpact();
                                    widget.controller.declareRepayment(
                                      payerId: ob.debtorId,
                                      payeeId: ob.creditorId,
                                      currency: ob.currency,
                                      amountMinor: rem,
                                      targetObligationId: ob.obligationId,
                                      note: '履行正式结算单义务',
                                    );
                                  },
                                  child: const Text('记已还'),
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

            // 5. 结算快照共同确认卡片
            if (snap.snapshots.isNotEmpty) ...[
              const SizedBox(height: 14),
              ...snap.snapshots.map((item) {
                final alreadySigned =
                    item.approvedBy.containsKey(actor.participantId);
                final isRequired =
                    item.requiredApprovers.contains(actor.participantId);
                final canCommit = item.isReadyToCommit &&
                    actor.active &&
                    actor.role.canPublishSettlement &&
                    snap.formalSettlementBlocker == null;

                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
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
                                color: item.isCommitted
                                    ? AppTheme.creditEmerald
                                        .withValues(alpha: 0.14)
                                    : AppTheme.primaryTeal
                                        .withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                item.mode.label,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: item.isCommitted
                                      ? AppTheme.creditEmerald
                                      : AppTheme.primaryTeal,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                item.statusLabel,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                            '冻结币种：${item.settlementCurrency ?? "按各原币"} · 账目 ${item.coveredExpenseCount} · 还款 ${item.coveredRepaymentCount} · 旧义务 ${item.novatedObligationCount}',
                            style: const TextStyle(fontSize: 12)),
                        const SizedBox(height: 6),
                        SelectableText('快照指纹：${item.snapshotDigest}',
                            style: const TextStyle(
                                fontSize: 10, color: AppTheme.mutedSlate)),
                        ExpansionTile(
                          title: Text('冻结方案：${item.transfers.length} 笔转账'),
                          subtitle: const Text('确认针对此快照，不受上方本地试算开关影响',
                              style: TextStyle(fontSize: 11)),
                          children: [
                            if (item.transfers.isEmpty)
                              const Padding(
                                  padding: EdgeInsets.all(8),
                                  child: Text('本方案抵销原始欠款，生效后无需新转账')),
                            for (final transfer in item.transfers)
                              ListTile(
                                  dense: true,
                                  title: Text(
                                      '${snap.nameOf(transfer.debtorId)} → ${snap.nameOf(transfer.creditorId)}'),
                                  subtitle: Text(
                                      '${MoneyFormatter.formatMinor(transfer.amountMinor, transfer.currency, decimals: snap.decimalsOf(transfer.currency))} ${transfer.currency}')),
                            if (item.mode.mergeCurrency)
                              for (final rate in item.fxRates)
                                Padding(
                                    padding: const EdgeInsets.all(6),
                                    child: Text('冻结汇率：${rate.displayRatio}')),
                          ],
                        ),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: item.requiredApprovers.map((pid) {
                            final signed = item.approvedBy.containsKey(pid);
                            return Chip(
                              visualDensity: VisualDensity.compact,
                              avatar: Icon(
                                signed
                                    ? Icons.check_circle
                                    : Icons.schedule_rounded,
                                size: 15,
                                color: signed
                                    ? AppTheme.creditEmerald
                                    : AppTheme.conflictAmber,
                              ),
                              label: Text(
                                '${snap.nameOf(pid)} ${signed ? "已确认" : "待确认"}',
                                style: const TextStyle(fontSize: 11),
                              ),
                            );
                          }).toList(),
                        ),
                        if (!item.isCommitted) ...[
                          const SizedBox(height: 10),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (isRequired &&
                                  !alreadySigned &&
                                  actor.active &&
                                  snap.formalSettlementBlocker == null)
                                OutlinedButton.icon(
                                  onPressed: () {
                                    HapticFeedback.lightImpact();
                                    widget.controller
                                        .approveSettlement(item.snapshotId);
                                  },
                                  icon: const Icon(
                                    Icons.draw_outlined,
                                    size: 16,
                                  ),
                                  label: Text('我同意此方案 (${actor.displayName})'),
                                ),
                              if (canCommit) ...[
                                const SizedBox(width: 8),
                                FilledButton.icon(
                                  onPressed: () {
                                    HapticFeedback.lightImpact();
                                    widget.controller
                                        .commitSettlement(item.snapshotId);
                                  },
                                  icon: const Icon(
                                    Icons.check_circle_outline,
                                    size: 16,
                                  ),
                                  label: const Text('正式生效'),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              }),
            ],
          ],
        );
      },
    );
  }

  Future<void> _showCustomRepaymentDialog(
    BuildContext context,
    UiWorkspaceSnapshotModel snap,
  ) async {
    String payerId = snap.activeActorId;
    String payeeId = snap.participants
        .firstWhere((p) => p.participantId != payerId)
        .participantId;
    String currency = 'CNY';
    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController(text: '线下/微信转账还款');

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('记一笔还款'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    value: payerId,
                    decoration: const InputDecoration(labelText: '谁付的钱'),
                    items: snap.participants
                        .map(
                          (p) => DropdownMenuItem(
                            value: p.participantId,
                            child: Text(p.displayName),
                          ),
                        )
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setDialogState(() => payerId = v);
                    },
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: payeeId,
                    decoration: const InputDecoration(labelText: '还给谁'),
                    items: snap.participants
                        .where((p) => p.participantId != payerId)
                        .map(
                          (p) => DropdownMenuItem(
                            value: p.participantId,
                            child: Text(p.displayName),
                          ),
                        )
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setDialogState(() => payeeId = v);
                    },
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: amountCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(labelText: '金额'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      DropdownButton<String>(
                        value: currency,
                        items: snap.currencies.keys
                            .map(
                              (c) => DropdownMenuItem(value: c, child: Text(c)),
                            )
                            .toList(),
                        onChanged: (v) {
                          if (v != null) setDialogState(() => currency = v);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: noteCtrl,
                    decoration: const InputDecoration(labelText: '备注'),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () async {
                    final amt = MoneyFormatter.parseMajorToMinor(
                      amountCtrl.text,
                      snap.decimalsOf(currency),
                    );
                    if (amt != null && amt > 0) {
                      await widget.controller.declareRepayment(
                        payerId: payerId,
                        payeeId: payeeId,
                        currency: currency,
                        amountMinor: amt,
                        note: noteCtrl.text.trim(),
                      );
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    }
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showFxRateDialog(
    BuildContext context,
    UiWorkspaceSnapshotModel snap,
  ) async {
    String baseCurr =
        snap.currencies.keys.firstWhere((c) => c != snap.settlementCurrency);
    final numCtrl = TextEditingController();
    final denCtrl = TextEditingController(text: '1');

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('设置结算汇率'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    value: baseCurr,
                    decoration: InputDecoration(
                        labelText: '原币币种 (折算至 ${snap.settlementCurrency})'),
                    items: snap.currencies.keys
                        .where((c) => c != snap.settlementCurrency)
                        .map(
                          (c) => DropdownMenuItem(value: c, child: Text(c)),
                        )
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setDialogState(() => baseCurr = v);
                    },
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: denCtrl,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: '每多少 $baseCurr',
                          ),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Text('='),
                      ),
                      Expanded(
                        child: TextField(
                          controller: numCtrl,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: '折合多少 ${snap.settlementCurrency}',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () async {
                    final n = int.tryParse(numCtrl.text.trim()) ?? 0;
                    final d = int.tryParse(denCtrl.text.trim()) ?? 0;
                    if (n > 0 && d > 0) {
                      await widget.controller.setFxRate(
                        baseCurrency: baseCurr,
                        quoteCurrency: snap.settlementCurrency,
                        numerator: n,
                        denominator: d,
                      );
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    }
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showDisputeRepaymentDialog(
    BuildContext context,
    RepaymentItemModel rep,
  ) async {
    final reasonCtrl = TextEditingController(text: '尚未收到转账，请核对金额或账号');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('提出收款异议'),
        content: TextField(
          key: const ValueKey('dispute_repayment_reason_input'),
          controller: reasonCtrl,
          decoration: const InputDecoration(
            labelText: '异议原因',
            hintText: '说明未到账或金额不符原因',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm_dispute_repayment_button'),
            onPressed: () async {
              final ok = await widget.controller.disputeRepayment(
                paymentId: rep.paymentId,
                declareEventId: rep.declareEventId,
                reason: reasonCtrl.text,
              );
              if (!ctx.mounted) return;
              if (ok) {
                Navigator.of(ctx).pop();
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(widget.controller.lastError ?? '提交异议失败'),
                  ),
                );
              }
            },
            child: const Text('提交异议'),
          ),
        ],
      ),
    );
    reasonCtrl.dispose();
  }

  Future<void> _showMapLateRepaymentDialog(
    BuildContext context,
    UiWorkspaceSnapshotModel snap,
    RepaymentItemModel rep,
  ) async {
    final candidates = snap.activeObligations
        .where((ob) =>
            ob.debtorId == rep.payerId &&
            ob.creditorId == rep.payeeId &&
            ob.currency == rep.currency &&
            ob.remainingMinor > 0)
        .toList();
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前无同币种、同收付双方的待履行结算义务可映射')),
      );
      return;
    }
    var selectedObId = candidates.first.obligationId;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) => AlertDialog(
          title: const Text('映射迟到还款到新结算单'),
          content: DropdownButtonFormField<String>(
            initialValue: selectedObId,
            decoration: const InputDecoration(labelText: '选择目标结算义务'),
            items: candidates
                .map(
                  (ob) => DropdownMenuItem(
                    value: ob.obligationId,
                    child: Text(
                      '${snap.nameOf(ob.debtorId)} → ${snap.nameOf(ob.creditorId)} (待还 ${MoneyFormatter.formatMinor(ob.remainingMinor, ob.currency, decimals: snap.decimalsOf(ob.currency))})',
                    ),
                  ),
                )
                .toList(),
            onChanged: (v) {
              if (v != null) setStateDialog(() => selectedObId = v);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('confirm_map_late_repayment_button'),
              onPressed: () async {
                final ok = await widget.controller.mapLateRepayment(
                  paymentId: rep.paymentId,
                  targetObligationId: selectedObId,
                );
                if (!ctx.mounted) return;
                if (ok) {
                  Navigator.of(ctx).pop();
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(widget.controller.lastError ?? '映射义务失败'),
                    ),
                  );
                }
              },
              child: const Text('确认映射'),
            ),
          ],
        ),
      ),
    );
  }
}

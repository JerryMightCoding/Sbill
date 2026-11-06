import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/ledger_models.dart';
import '../../models/expense_list_options.dart';
import 'expense_list_options_sheet.dart';
import '../../state/ledger_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/animated_amount_text.dart';
import 'conflict_resolution_screen.dart';
import 'expense_detail_screen.dart';
import 'expense_editor_sheet.dart';
import 'settlement_center_screen.dart';
import 'sync_center_screen.dart';
import 'companion_center_screen.dart';

enum _BillFilter {
  all('全部账单'),
  mine('与我相关'),
  conflicts('待处理冲突');

  const _BillFilter(this.label);
  final String label;
}

/// Modern, Streamlined Group Home Screen:
/// - Clean 3-tab bottom navigation (`账单` / `结算与收付` / `同步与伙伴`) with `SmoothTabTransition`
/// - Top-right compact persona switcher pill + bottom sheet
/// - Hero balance card with 1-tap jump to Settlement Center
/// - Tactile `PressableScaleCard` bill items showing each bill's personal net impact ("我应收 +¥350" / "我应付 -$25")
class GroupHomeScreen extends StatefulWidget {
  const GroupHomeScreen({
    super.key,
    required this.controller,
  });

  final LedgerController controller;

  @override
  State<GroupHomeScreen> createState() => _GroupHomeScreenState();
}

class _GroupHomeScreenState extends State<GroupHomeScreen> {
  int _tabIndex = 0;
  _BillFilter _billFilter = _BillFilter.all;
  String? _ledgerId;
  ExpenseListOptions _listOptions = const ExpenseListOptions();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final snap = widget.controller.snapshot;
        if (snap == null) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final actor = snap.activeActor;
        final byCurrPreview = snap.settlementPreviews['ByCurrencyPairwise'];
        final mergedPreview =
            snap.settlementPreviews['MergedCurrencyMinTransfers'];
        final mergedNet =
            mergedPreview?.netBalancesByCurrency[snap.settlementCurrency]
                    ?[actor.participantId] ??
                0;

        return Scaffold(
          appBar: AppBar(
            leading: widget.controller.isAppMode
                ? IconButton(
                    tooltip: '切换账本',
                    icon: const Icon(Icons.menu_book_outlined),
                    onPressed: widget.controller.isLoading
                        ? null
                        : widget.controller.showLedgers,
                  )
                : null,
            title: Text(
              snap.groupName,
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            ),
            actions: [
              // 右上角精致的身份视角胶囊按钮
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: ActionChip(
                  avatar: CircleAvatar(
                    backgroundColor: AppTheme.primaryTeal,
                    child: Text(
                      actor.displayName.characters.first,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  label: Text(
                    actor.displayName,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  onPressed: () => _showPersonaPickerSheet(context, snap),
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              if (widget.controller.lastError != null)
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppTheme.debtRose.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: AppTheme.debtRose,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.controller.lastError!,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.debtRose,
                          ),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: widget.controller.clearError,
                        icon: const Icon(Icons.close, size: 16),
                      ),
                    ],
                  ),
                ),

              // 顶部多币种个人净头寸卡片
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                child: AnimatedContainer(
                  duration: AppTheme.mediumAnim,
                  curve: AppTheme.smoothCurve,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: mergedNet >= 0
                          ? const [AppTheme.primaryTeal, AppTheme.primaryDark]
                          : const [Color(0xFF334155), Color(0xFF0F172A)],
                    ),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '我的净余额 (${actor.displayName})',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          InkWell(
                            borderRadius: BorderRadius.circular(99),
                            onTap: () {
                              HapticFeedback.selectionClick();
                              setState(() => _tabIndex = 1);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white24,
                                borderRadius: BorderRadius.circular(99),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    mergedPreview == null
                                        ? '查看原币余额'
                                        : mergedNet > 0
                                            ? '去收款/结算'
                                            : (mergedNet < 0
                                                ? '去还款/结算'
                                                : '个人净额为零'),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  const Icon(
                                    Icons.chevron_right_rounded,
                                    size: 15,
                                    color: Colors.white,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            mergedPreview == null
                                ? '尚未设置折算汇率'
                                : '折合 ${snap.settlementCurrency} ',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                          if (mergedPreview != null)
                            AnimatedAmountText(
                              amountMinor: mergedNet,
                              currency: snap.settlementCurrency,
                              decimals:
                                  snap.decimalsOf(snap.settlementCurrency),
                              showPlus: true,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                        ],
                      ),
                      if (byCurrPreview != null &&
                          byCurrPreview.netBalancesByCurrency.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: byCurrPreview.netBalancesByCurrency.entries
                              .map((currEntry) {
                            final curr = currEntry.key;
                            final myBal =
                                currEntry.value[actor.participantId] ?? 0;
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black26,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '$curr ',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 11,
                                    ),
                                  ),
                                  AnimatedAmountText(
                                    amountMinor: myBal,
                                    currency: curr,
                                    decimals: snap.decimalsOf(curr),
                                    showPlus: true,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              // 并发冲突动态警示条
              AnimatedSize(
                duration: AppTheme.fastAnim,
                curve: AppTheme.smoothCurve,
                child: snap.conflictCount > 0
                    ? Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () {
                            final firstConflict =
                                snap.expenses.firstWhere((e) => e.hasConflict);
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => ConflictResolutionScreen(
                                  controller: widget.controller,
                                  expenseId: firstConflict.expenseId,
                                ),
                              ),
                            );
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.conflictAmber
                                  .withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.warning_amber_rounded,
                                  color: AppTheme.conflictAmber,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '有 ${snap.conflictCount} 笔账单存在多端并发修改冲突，点击对比合并',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const Icon(Icons.chevron_right, size: 18),
                              ],
                            ),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),

              // 3 栏主视图平滑过渡
              Expanded(
                child: SmoothTabTransition(
                  currentIndex: _tabIndex,
                  child: _buildCurrentTab(context, snap),
                ),
              ),
            ],
          ),
          floatingActionButton: _tabIndex == 0 &&
                  (!widget.controller.isAppMode || widget.controller.canWrite)
              ? FloatingActionButton.extended(
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    showModalBottomSheet<bool>(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (_) => ExpenseEditorSheet(
                        controller: widget.controller,
                      ),
                    );
                  },
                  icon: const Icon(Icons.add_rounded),
                  label: Text(
                    snap.expenses.isEmpty ? '记第一笔' : '记一笔',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                )
              : null,
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tabIndex,
            onDestinationSelected: (idx) {
              HapticFeedback.selectionClick();
              setState(() => _tabIndex = idx);
            },
            destinations: [
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: snap.conflictCount > 0,
                  label: Text('${snap.conflictCount}'),
                  child: const Icon(Icons.receipt_long_outlined),
                ),
                selectedIcon: const Icon(Icons.receipt_long_rounded),
                label: '账单 (${snap.expenses.length})',
              ),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: snap.pendingRepaymentCount > 0 ||
                      snap.activeObligations.any((ob) => !ob.isFullyPaid),
                  label: Text(
                    '${snap.pendingRepaymentCount + snap.activeObligations.where((ob) => !ob.isFullyPaid).length}',
                  ),
                  child: const Icon(Icons.account_balance_wallet_outlined),
                ),
                selectedIcon: const Icon(Icons.account_balance_wallet_rounded),
                label: '结算与收付',
              ),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: snap.webDavStatus.pendingUploadCount > 0,
                  label: Text('${snap.webDavStatus.pendingUploadCount}'),
                  child: const Icon(Icons.hub_outlined),
                ),
                selectedIcon: const Icon(Icons.hub_rounded),
                label: '同步与伙伴',
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCurrentTab(
    BuildContext context,
    UiWorkspaceSnapshotModel snap,
  ) {
    switch (_tabIndex) {
      case 0:
        return _buildExpensesTab(context, snap);
      case 1:
        return SettlementCenterScreen(controller: widget.controller);
      default:
        return widget.controller.isAppMode
            ? CompanionCenterScreen(controller: widget.controller)
            : SyncCenterScreen(controller: widget.controller);
    }
  }

  Widget _buildExpensesTab(
    BuildContext context,
    UiWorkspaceSnapshotModel snap,
  ) {
    if (_ledgerId != snap.groupId) {
      _ledgerId = snap.groupId;
      _billFilter = _BillFilter.all;
      _listOptions = const ExpenseListOptions();
    }
    final myId = snap.activeActorId;
    final quickFiltered = snap.expenses.where((item) {
      if (_billFilter == _BillFilter.conflicts) {
        return item.hasConflict;
      }
      if (_billFilter == _BillFilter.mine) {
        final rev = item.displayRevision;
        final paidByMe = rev.payers.any((p) => p.participantId == myId);
        final sharedByMe = (rev.resolvedShares[myId] ?? 0) > 0;
        return paidByMe || sharedByMe;
      }
      return true;
    });
    final sections = _listOptions.sections(quickFiltered, snap.allCategories);
    final entries = <({String? header, String? subtotal, UiExpenseViewModel? expense})>[
      for (final section in sections) ...[
        if (section.label != null)
          (
            header: '${section.label} · ${section.expenses.length} 笔',
            subtotal: section.subtotalLabel(snap.decimalsOf),
            expense: null,
          ),
        for (final expense in section.expenses) (header: null, subtotal: null, expense: expense),
      ]
    ];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _BillFilter.values.map((f) {
                      final selected = _billFilter == f;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          visualDensity: VisualDensity.compact,
                          selected: selected,
                          onSelected: (_) {
                            HapticFeedback.selectionClick();
                            setState(() => _billFilter = f);
                          },
                          label: Text(
                            f.label,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
              ActionChip(
                key: const ValueKey('open_expense_options'),
                visualDensity: VisualDensity.compact,
                avatar: const Icon(Icons.tune, size: 15),
                label: Text(_listOptions.filterCount == 0
                    ? (_listOptions.grouping == ExpenseGrouping.date && _listOptions.order == ExpenseOrder.newest ? '排序/筛选' : _listOptions.grouping.label)
                    : '筛选${_listOptions.filterCount}'),
                onPressed: () async {
                  final next = await showModalBottomSheet<ExpenseListOptions>(
                    context: context, isScrollControlled: true,
                    builder: (_) => ExpenseListOptionsSheet(snapshot: snap, initial: _listOptions),
                  );
                  if (next != null && mounted) setState(() => _listOptions = next);
                },
              ),
              if (_listOptions.filterCount > 0 || _listOptions.order != ExpenseOrder.newest || _listOptions.grouping != ExpenseGrouping.date)
                IconButton(
                  key: const ValueKey('clear_expense_options'),
                  onPressed: () => setState(() => _listOptions = const ExpenseListOptions()),
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: '重置排序与筛选',
                ),
            ],
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? Center(
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.receipt_long_outlined,
                            size: 44, color: AppTheme.primaryTeal),
                        const SizedBox(height: 16),
                        Text(snap.expenses.isEmpty ? '出行账本准备好了' : '当前筛选下暂无账单',
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        Text(
                            snap.expenses.isEmpty
                                ? '点击“记第一笔”开始。\n伙伴可在“同步与伙伴”中添加或邀请认领。'
                                : '换个筛选条件看看。',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: AppTheme.mutedSlate, height: 1.6)),
                      ])))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 92),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    if (entry.header != null) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Expanded(
                              child: Text(
                                entry.header!,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.mutedSlate,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                entry.subtotal ?? '',
                                textAlign: TextAlign.end,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.deepSlate,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    final item = entry.expense!;
                    final rev = item.displayRevision;
                    final time = rev.details?.localTime;
                    final timeText = time == null ? '' : _listOptions.grouping == ExpenseGrouping.date ?
                        '${expenseTimeLabel(time)} · ' : '${expenseDateLabel(time)} ${expenseTimeLabel(time)} · ';
                    final decimals = snap.decimalsOf(rev.currency);

                    // 计算这笔账单对当前成员本人的净影响 (myPaid - myShare)
                    final myPaid = rev.payers
                        .where((p) => p.participantId == myId)
                        .fold<int>(0, (s, p) => s + p.amountMinor);
                    final myShare = rev.resolvedShares[myId] ?? 0;
                    final myNet = myPaid - myShare;

                    final payerNames = rev.payers
                        .map((p) => snap.nameOf(p.participantId))
                        .join('、');

                    return PressableScaleCard(
                      key: ValueKey(
                        '${item.expenseId}_${item.activeRevisionEventId}',
                      ),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ExpenseDetailScreen(
                              controller: widget.controller,
                              expenseId: item.expenseId,
                            ),
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    rev.title,
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                      decoration: rev.voided
                                          ? TextDecoration.lineThrough
                                          : null,
                                    ),
                                  ),
                                ),
                                AnimatedAmountText(
                                  amountMinor: rev.totalMinor,
                                  currency: rev.currency,
                                  decimals: decimals,
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w900,
                                    color: rev.voided
                                        ? Colors.grey
                                        : AppTheme.deepSlate,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '$timeText$payerNames 先付 · ${rev.resolvedShares.length}人${rev.splitRule.kind.label}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.mutedSlate,
                                    ),
                                  ),
                                ),
                                if (item.hasConflict)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppTheme.conflictAmber
                                          .withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Text(
                                      '待解决冲突',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: AppTheme.conflictAmber,
                                      ),
                                    ),
                                  )
                                else if (myNet != 0 && !rev.voided)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: (myNet > 0
                                              ? AppTheme.creditEmerald
                                              : AppTheme.debtRose)
                                          .withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      myNet > 0
                                          ? '我应收 ${MoneyFormatter.formatMinor(myNet, rev.currency, decimals: decimals, showPlus: true)}'
                                          : '我应付 ${MoneyFormatter.formatMinor(myNet.abs(), rev.currency, decimals: decimals)}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: myNet > 0
                                            ? AppTheme.creditEmerald
                                            : AppTheme.debtRose,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _showPersonaPickerSheet(
    BuildContext context,
    UiWorkspaceSnapshotModel snap,
  ) async {
    if (widget.controller.isAppMode) {
      await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
                title: Text(
                    '${snap.activeActor.displayName} · ${snap.activeActor.role.label}'),
                content: const Text(
                    '此账本只能使用本机已绑定的身份操作，不能切换成其他伙伴。\n伙伴与权限在“同步与伙伴”中管理。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('知道了'))
                ],
              ));
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '切换当前查看/操作视角',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '单机演示时可随时切换不同同行伙伴视角，体验各自的净余额、管理员改账及收款人确认。',
                  style: TextStyle(fontSize: 12, color: AppTheme.mutedSlate),
                ),
                const SizedBox(height: 12),
                ...snap.participants.map((p) {
                  final selected = p.participantId == snap.activeActorId;
                  return ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    tileColor: selected
                        ? AppTheme.primaryTeal.withValues(alpha: 0.08)
                        : null,
                    leading: CircleAvatar(
                      backgroundColor:
                          selected ? AppTheme.primaryTeal : AppTheme.surfaceBg,
                      child: Text(
                        p.participantId,
                        style: TextStyle(
                          color: selected ? Colors.white : AppTheme.primaryTeal,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    title: Text(
                      p.displayName,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      p.role.label,
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: selected
                        ? const Icon(
                            Icons.check_circle_rounded,
                            color: AppTheme.primaryTeal,
                          )
                        : null,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      widget.controller.switchActor(p.participantId);
                      Navigator.of(ctx).pop();
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }
}

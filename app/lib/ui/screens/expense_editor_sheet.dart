import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/ledger_models.dart';
import '../../models/expense_list_options.dart';
import '../../state/ledger_controller.dart';
import '../theme/app_theme.dart';

/// Intuitive M4 Expense Editor Sheet:
/// - Strict single-select category chips with tap-again-to-deselect
/// - Custom category creation with a curated 36-icon travel Emoji library + free keyboard Emoji input
///   (persisted in SQLite across app restarts)
/// - 1-tap Single Payer mode by default + smooth `AnimatedSize` expansion into Multi-Payer / Foreign-Card mode
/// - 4 Split modes with live Largest-Remainder per-person preview
class ExpenseEditorSheet extends StatefulWidget {
  const ExpenseEditorSheet({
    super.key,
    required this.controller,
    this.existingExpense,
    this.overrideParentRevisionIds,
    this.initialDraft,
  });

  final LedgerController controller;
  final UiExpenseViewModel? existingExpense;
  final List<String>? overrideParentRevisionIds;
  final ExpenseRevisionModel? initialDraft;

  @override
  State<ExpenseEditorSheet> createState() => _ExpenseEditorSheetState();
}

class _ExpenseEditorSheetState extends State<ExpenseEditorSheet> {
  static const List<String> _travelEmojiPalette = [
    '🏨',
    '🏡',
    '⛺',
    '🍜',
    '🍣',
    '🍲',
    '☕',
    '🍰',
    '🍺',
    '🚄',
    '✈️',
    '🚕',
    '🚗',
    '⛽',
    '⛴️',
    '🎫',
    '🎢',
    '♨️',
    '🎿',
    '🤿',
    '🎭',
    '🖼️',
    '🛍️',
    '🎁',
    '💄',
    '👕',
    '🏪',
    '📸',
    '📶',
    '🛂',
    '🛡️',
    '💊',
    '🧳',
    '🔋',
    '🐾',
    '🏷️',
  ];

  String? _selectedCategoryId;
  ExpenseCategoryModel? _initialCategory;
  DateTime? _occurredAt;
  late String _currency;
  late SplitModeKind _splitKind;
  late bool _multiPayerMode;
  late String _singlePayerId;

  late TextEditingController _titleCtrl;
  late TextEditingController _totalCtrl;
  late TextEditingController _noteCtrl;
  late TextEditingController _reasonCtrl;

  final Map<String, bool> _payerEnabled = {};
  final Map<String, TextEditingController> _payerAmountCtrls = {};
  final Map<String, bool> _payerUseForeign = {};
  final Map<String, String> _payerForeignCurr = {};
  final Map<String, TextEditingController> _payerForeignAmtCtrls = {};
  final Map<String, TextEditingController> _payerFxNumCtrls = {};

  final Set<String> _equalParticipants = {};
  final Map<String, TextEditingController> _exactShareCtrls = {};
  final Map<String, TextEditingController> _weightCtrls = {};

  @override
  void initState() {
    super.initState();
    final snap = widget.controller.snapshot!;
    final draft =
        widget.initialDraft ?? widget.existingExpense?.displayRevision;

    _currency = draft?.currency ?? 'CNY';
    _splitKind = draft?.splitRule.kind ?? SplitModeKind.equal;
    final decimals = snap.decimalsOf(_currency);

    _multiPayerMode = draft != null &&
        (draft.payers.length > 1 ||
            draft.payers.any((p) => p.originalCurrency != null));
    _singlePayerId = draft != null && draft.payers.isNotEmpty
        ? draft.payers.first.participantId
        : snap.activeActorId;

    final initialTitle = draft?.title ?? '';
    _titleCtrl = TextEditingController(text: initialTitle);

    _occurredAt = draft == null ? DateTime.now() : draft.details?.localTime;
    _initialCategory = draft == null ? null : expenseCategoryOf(draft, snap.allCategories);
    _selectedCategoryId = _initialCategory?.id;

    _totalCtrl = TextEditingController(
      text: draft != null
          ? MoneyFormatter.formatMinor(
              draft.totalMinor,
              _currency,
              decimals: decimals,
              withSymbol: false,
            ).replaceAll(',', '')
          : '',
    );
    _noteCtrl = TextEditingController(text: draft?.note ?? '');
    _reasonCtrl = TextEditingController(
      text: widget.existingExpense != null ? '核对并修订账单明细' : '创建账单',
    );

    for (final p in _participants) {
      final pid = p.participantId;
      final existingPayer = draft?.payers
          .cast<PayerContributionModel?>()
          .firstWhere((x) => x?.participantId == pid, orElse: () => null);

      _payerEnabled[pid] =
          existingPayer != null || (draft == null && pid == _singlePayerId);
      _payerAmountCtrls[pid] = TextEditingController(
        text: existingPayer != null
            ? MoneyFormatter.formatMinor(
                existingPayer.amountMinor,
                _currency,
                decimals: decimals,
                withSymbol: false,
              ).replaceAll(',', '')
            : '',
      );
      _payerUseForeign[pid] = existingPayer?.originalCurrency != null;
      _payerForeignCurr[pid] = existingPayer?.originalCurrency ?? 'USD';
      _payerForeignAmtCtrls[pid] = TextEditingController(
        text: existingPayer?.originalAmountMinor != null
            ? MoneyFormatter.formatMinor(existingPayer!.originalAmountMinor!,
                    _payerForeignCurr[pid]!,
                    decimals: snap.decimalsOf(_payerForeignCurr[pid]!),
                    withSymbol: false)
                .replaceAll(',', '')
            : '',
      );
      _payerFxNumCtrls[pid] = TextEditingController(
        text: existingPayer?.frozenFxRate?.inputText ?? '',
      );

      final existingShare = draft?.resolvedShares[pid] ?? 0;
      _exactShareCtrls[pid] = TextEditingController(
        text: existingShare > 0
            ? MoneyFormatter.formatMinor(
                existingShare,
                _currency,
                decimals: decimals,
                withSymbol: false,
              ).replaceAll(',', '')
            : '',
      );

      final defaultWeight =
          draft?.splitRule.weights[pid] ?? draft?.splitRule.ratios[pid] ?? 1;
      _weightCtrls[pid] = TextEditingController(text: defaultWeight.toString());

      if ((draft == null && p.active) ||
          draft?.resolvedShares.containsKey(pid) == true ||
          draft?.splitRule.equalParticipants.contains(pid) == true) {
        _equalParticipants.add(pid);
      }
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _totalCtrl.dispose();
    _noteCtrl.dispose();
    _reasonCtrl.dispose();
    for (final c in _payerAmountCtrls.values) {
      c.dispose();
    }
    for (final c in _payerForeignAmtCtrls.values) {
      c.dispose();
    }
    for (final c in _payerFxNumCtrls.values) {
      c.dispose();
    }
    for (final c in _exactShareCtrls.values) {
      c.dispose();
    }
    for (final c in _weightCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Strips any leading category prefix from `rawTitle` so switching or deselecting categories
  /// never stacks multiple category names into the title field.
  String _stripKnownCategoryPrefix(
    String rawTitle,
    List<ExpenseCategoryModel> allCategories,
  ) {
    var text = rawTitle.trim();
    for (final cat in allCategories) {
      final prefixWithIcon = '${cat.icon} ${cat.name} · ';
      final prefixPlain = '${cat.name} · ';
      final exactWithIcon = '${cat.icon} ${cat.name}';
      if (text.startsWith(prefixWithIcon)) {
        return text.substring(prefixWithIcon.length).trim();
      }
      if (text.startsWith(prefixPlain)) {
        return text.substring(prefixPlain.length).trim();
      }
      if (text == exactWithIcon || text == cat.name) {
        return '';
      }
    }
    return text;
  }

  void _toggleCategorySelection(
    ExpenseCategoryModel tapped,
    List<ExpenseCategoryModel> allCategories,
  ) {
    HapticFeedback.selectionClick();
    final userCustomTitle =
        _stripKnownCategoryPrefix(_titleCtrl.text, allCategories);

    setState(() {
      if (_selectedCategoryId == tapped.id) {
        // Tap already-selected category -> deselect and restore only user's custom text
        _selectedCategoryId = null;
        _titleCtrl.text = userCustomTitle;
      } else {
        // Single-select the new category and replace any previous category prefix cleanly
        _selectedCategoryId = tapped.id;
        if (userCustomTitle.isEmpty) {
          _titleCtrl.text = '${tapped.icon} ${tapped.name}';
        } else {
          _titleCtrl.text = '${tapped.icon} ${tapped.name} · $userCustomTitle';
        }
      }
      _titleCtrl.selection = TextSelection.fromPosition(
        TextPosition(offset: _titleCtrl.text.length),
      );
    });
  }

  List<ParticipantModel> get _participants =>
      widget.controller.snapshot!.participants
          .where((p) =>
              p.active ||
              widget.existingExpense != null ||
              widget.initialDraft != null)
          .toList();

  int get _decimals => widget.controller.snapshot?.decimalsOf(_currency) ?? 2;

  int get _totalMinor =>
      MoneyFormatter.parseMajorToMinor(_totalCtrl.text, _decimals) ?? 0;

  List<PayerContributionModel> _collectPayers() {
    if (!_multiPayerMode) {
      final total = _totalMinor;
      if (total <= 0) return const [];
      return [
        PayerContributionModel(
          participantId: _singlePayerId,
          amountMinor: total,
        ),
      ];
    }

    final snap = widget.controller.snapshot!;
    final result = <PayerContributionModel>[];
    for (final p in _participants) {
      final pid = p.participantId;
      if (_payerEnabled[pid] != true) continue;
      final amt = MoneyFormatter.parseMajorToMinor(
            _payerAmountCtrls[pid]?.text ?? '',
            _decimals,
          ) ??
          0;
      if (amt <= 0) continue;

      if (_payerUseForeign[pid] == true) {
        final origCurr = _payerForeignCurr[pid] ?? 'USD';
        final origDec = snap.decimalsOf(origCurr);
        final origAmt = MoneyFormatter.parseMajorToMinor(
              _payerForeignAmtCtrls[pid]?.text ?? '',
              origDec,
            ) ??
            0;
        final rate = FxRateSpecModel.parse(
            origCurr, _currency, _payerFxNumCtrls[pid]?.text ?? '');
        if (origAmt <= 0 ||
            rate == null ||
            rate.convertMinor(origAmt, origDec, _decimals) != amt) {
          continue;
        }
        result.add(
          PayerContributionModel(
            participantId: pid,
            amountMinor: amt,
            originalCurrency: origCurr,
            originalAmountMinor: origAmt,
            frozenFxRate: rate,
          ),
        );
      } else {
        result.add(
          PayerContributionModel(
            participantId: pid,
            amountMinor: amt,
          ),
        );
      }
    }
    return result;
  }

  Map<String, int> _previewShares() {
    final total = _totalMinor;
    switch (_splitKind) {
      case SplitModeKind.equal:
        return MoneyFormatter.apportionByWeights(
          total,
          {for (final pid in _equalParticipants) pid: 1},
        );
      case SplitModeKind.exactAmounts:
        final map = <String, int>{};
        for (final entry in _exactShareCtrls.entries) {
          final v =
              MoneyFormatter.parseMajorToMinor(entry.value.text, _decimals) ??
                  0;
          if (v > 0) map[entry.key] = v;
        }
        return map;
      case SplitModeKind.ratios:
      case SplitModeKind.weights:
        final weights = <String, int>{};
        for (final entry in _weightCtrls.entries) {
          final w = int.tryParse(entry.value.text.trim()) ?? 0;
          if (w > 0) weights[entry.key] = w;
        }
        return MoneyFormatter.apportionByWeights(total, weights);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final snap = widget.controller.snapshot!;
        final allCategories = [
      ...snap.allCategories,
      if (_initialCategory != null && !snap.allCategories.any((c) => c.id == _initialCategory!.id))
        _initialCategory!,
    ];
        final totalMinor = _totalMinor;
        final payers = _collectPayers();
        final sumPaid = payers.fold<int>(0, (s, p) => s + p.amountMinor);
        final previewShares = _previewShares();
        final sumShares = previewShares.values.fold<int>(0, (s, v) => s + v);

        final allPayersValid = !_multiPayerMode ||
            payers.length ==
                _payerEnabled.values.where((enabled) => enabled).length;
        final isBalanced = allPayersValid &&
            totalMinor > 0 &&
            sumPaid == totalMinor &&
            sumShares == totalMinor;

        return DraggableScrollableSheet(
          initialChildSize: 0.9,
          minChildSize: 0.65,
          maxChildSize: 0.96,
          expand: false,
          builder: (context, scrollController) {
            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.overrideParentRevisionIds != null
                                ? '合并解决并发冲突'
                                : (widget.existingExpense != null
                                    ? '修订账单'
                                    : '记一笔'),
                            style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
                      children: [
                        // 1. 单选分类栏（支持再次点击取消选中 + 新增/长按删除自定义分类）
                        Row(
                          children: [
                            const Text(
                              '账单分类 (单选，再点可取消)',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.mutedSlate,
                              ),
                            ),
                            const Spacer(),
                            if (snap.customCategories.isNotEmpty)
                              const Text(
                                '长按自定义分类可删除',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppTheme.mutedSlate,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              ...allCategories.map((cat) {
                                final selected = _selectedCategoryId == cat.id;
                                return Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: GestureDetector(
                                    onLongPress: cat.isCustom
                                        ? () =>
                                            _confirmDeleteCustomCategory(cat)
                                        : null,
                                    child: ChoiceChip(
                                      selected: selected,
                                      showCheckmark: false,
                                      backgroundColor: Colors.grey.shade100,
                                      selectedColor: AppTheme.primaryTeal
                                          .withValues(alpha: 0.15),
                                      side: BorderSide(
                                        color: selected
                                            ? AppTheme.primaryTeal
                                            : Colors.transparent,
                                        width: 1.2,
                                      ),
                                      label: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            '${cat.icon} ${cat.name}',
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: selected
                                                  ? FontWeight.w800
                                                  : FontWeight.w500,
                                              color: selected
                                                  ? AppTheme.primaryTeal
                                                  : AppTheme.deepSlate,
                                            ),
                                          ),
                                          if (selected) ...[
                                            const SizedBox(width: 4),
                                            const Icon(
                                              Icons.close_rounded,
                                              size: 14,
                                              color: AppTheme.primaryTeal,
                                            ),
                                          ],
                                        ],
                                      ),
                                      onSelected: (_) =>
                                          _toggleCategorySelection(
                                        cat,
                                        allCategories,
                                      ),
                                    ),
                                  ),
                                );
                              }),
                              ActionChip(
                                avatar: const Icon(
                                  Icons.add_rounded,
                                  size: 16,
                                  color: AppTheme.primaryTeal,
                                ),
                                backgroundColor: AppTheme.primaryTeal
                                    .withValues(alpha: 0.08),
                                side: BorderSide(
                                  color: AppTheme.primaryTeal
                                      .withValues(alpha: 0.3),
                                ),
                                label: const Text(
                                  '自定义分类',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.primaryTeal,
                                  ),
                                ),
                                onPressed: () =>
                                    _showAddCustomCategorySheet(context),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),

                        Row(children: [
                          const Icon(Icons.event, size: 18, color: AppTheme.primaryTeal),
                          const SizedBox(width: 8),
                          Expanded(child: Text(_occurredAt == null ? '未设置记账时间' :
                              '${expenseDateLabel(_occurredAt!)} ${expenseTimeLabel(_occurredAt!)}',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                          TextButton(key: const ValueKey('pick_expense_date'), onPressed: () async {
                            final initial = _occurredAt ?? DateTime.now();
                            final date = await showDatePicker(context: context, initialDate: initial,
                              firstDate: DateTime(1), lastDate: DateTime(9999, 12, 31));
                            if (date != null && mounted) {
                              setState(() => _occurredAt = DateTime(date.year, date.month, date.day, initial.hour, initial.minute));
                            }
                          }, child: const Text('选日期')),
                          TextButton(key: const ValueKey('pick_expense_time'), onPressed: () async {
                            final initial = _occurredAt ?? DateTime.now();
                            final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
                            if (time != null && mounted) {
                              setState(() => _occurredAt = DateTime(initial.year, initial.month, initial.day, time.hour, time.minute));
                            }
                          }, child: const Text('选时间')),
                          if (_occurredAt != null)
                            IconButton(key: const ValueKey('clear_expense_date'),
                              onPressed: () => setState(() => _occurredAt = null),
                              icon: const Icon(Icons.clear, size: 18), tooltip: '清除记账时间'),
                        ]),
                        const SizedBox(height: 8),
                        // 2. 醒目的金额与币种输入卡
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: AppTheme.surfaceBg,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Column(
                            children: [
                              TextField(
                                controller: _titleCtrl,
                                onChanged: (val) {
                                  // 若用户手动清空了包含当前分类名的标题，同步取消选中高亮
                                  if (_selectedCategoryId != null) {
                                    final currentCat = allCategories
                                        .where(
                                            (c) => c.id == _selectedCategoryId)
                                        .firstOrNull;
                                    if (currentCat != null &&
                                        !val.contains(currentCat.name)) {
                                      _selectedCategoryId = null;
                                    }
                                  }
                                  setState(() {});
                                },
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                                decoration: const InputDecoration(
                                  hintText: '输入消费内容，如：河口湖温泉酒店',
                                  border: InputBorder.none,
                                  isDense: true,
                                ),
                              ),
                              const Divider(height: 20),
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: DropdownButtonHideUnderline(
                                      child: DropdownButton<String>(
                                        value: _currency,
                                        isDense: true,
                                        items: snap.currencies.keys
                                            .map(
                                              (c) => DropdownMenuItem(
                                                value: c,
                                                child: Text(
                                                  '$c ${MoneyFormatter.symbolOf(c).trim()}',
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w800,
                                                    fontSize: 14,
                                                  ),
                                                ),
                                              ),
                                            )
                                            .toList(),
                                        onChanged: (val) {
                                          if (val != null) {
                                            HapticFeedback.selectionClick();
                                            setState(() {
                                              _currency = val;
                                              for (final pid
                                                  in _payerFxNumCtrls.keys) {
                                                _payerFxNumCtrls[pid]?.clear();
                                                if (_payerUseForeign[pid] ==
                                                    true) {
                                                  _payerAmountCtrls[pid]
                                                      ?.clear();
                                                }
                                              }
                                            });
                                          }
                                        },
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: TextField(
                                      controller: _totalCtrl,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                      style: const TextStyle(
                                        fontSize: 28,
                                        fontWeight: FontWeight.w900,
                                        color: AppTheme.primaryTeal,
                                      ),
                                      onChanged: (_) {
                                        if (!_multiPayerMode) {
                                          _payerAmountCtrls[_singlePayerId]
                                              ?.text = _totalCtrl.text;
                                        }
                                        setState(() {});
                                      },
                                      decoration: const InputDecoration(
                                        hintText: '0.00',
                                        border: InputBorder.none,
                                        isDense: true,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),

                        // 3. 谁付的钱？（默认单人快捷点选，按需丝滑展开多人拼付/外币折算）
                        Row(
                          children: [
                            const Text(
                              '谁先买单',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.deepSlate,
                              ),
                            ),
                            const Spacer(),
                            TextButton.icon(
                              onPressed: () {
                                HapticFeedback.selectionClick();
                                setState(() {
                                  _multiPayerMode = !_multiPayerMode;
                                  if (_multiPayerMode &&
                                      (_payerAmountCtrls[_singlePayerId]
                                              ?.text
                                              .isEmpty ??
                                          true)) {
                                    _payerEnabled[_singlePayerId] = true;
                                    _payerAmountCtrls[_singlePayerId]?.text =
                                        _totalCtrl.text;
                                  }
                                });
                              },
                              icon: Icon(
                                _multiPayerMode
                                    ? Icons.person_outline
                                    : Icons.group_add_outlined,
                                size: 16,
                              ),
                              label: Text(
                                _multiPayerMode ? '切回单人买单' : '多人拼付 / 外币卡折算',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                        AnimatedSize(
                          duration: AppTheme.fastAnim,
                          curve: AppTheme.smoothCurve,
                          child: !_multiPayerMode
                              ? Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: _participants.map((p) {
                                    final isSelected =
                                        p.participantId == _singlePayerId;
                                    return ChoiceChip(
                                      selected: isSelected,
                                      onSelected: (_) {
                                        HapticFeedback.selectionClick();
                                        setState(() {
                                          _singlePayerId = p.participantId;
                                        });
                                      },
                                      label: Text(
                                        p.displayName,
                                        style: TextStyle(
                                          fontWeight: isSelected
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                )
                              : Column(
                                  children: [
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: TextButton(
                                        onPressed: totalMinor > 0
                                            ? () {
                                                final activePayers =
                                                    _payerEnabled.entries
                                                        .where((e) => e.value)
                                                        .map((e) => e.key)
                                                        .toList();
                                                if (activePayers.isNotEmpty) {
                                                  final splitPaid =
                                                      MoneyFormatter
                                                          .apportionByWeights(
                                                    totalMinor,
                                                    {
                                                      for (final p
                                                          in activePayers)
                                                        p: 1
                                                    },
                                                  );
                                                  for (final e
                                                      in splitPaid.entries) {
                                                    _payerAmountCtrls[e.key]
                                                            ?.text =
                                                        MoneyFormatter
                                                            .formatMinor(
                                                      e.value,
                                                      _currency,
                                                      decimals: _decimals,
                                                      withSymbol: false,
                                                    ).replaceAll(',', '');
                                                  }
                                                  setState(() {});
                                                }
                                              }
                                            : null,
                                        child: const Text('按已选付款人平分垫付额'),
                                      ),
                                    ),
                                    ..._participants.map((p) {
                                      final pid = p.participantId;
                                      final enabled =
                                          _payerEnabled[pid] ?? false;
                                      final useForeign =
                                          _payerUseForeign[pid] ?? false;
                                      return AnimatedContainer(
                                        duration: AppTheme.fastAnim,
                                        margin:
                                            const EdgeInsets.only(bottom: 8),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: enabled
                                              ? AppTheme.primaryTeal
                                                  .withValues(alpha: 0.06)
                                              : Colors.grey.shade50,
                                          borderRadius:
                                              BorderRadius.circular(14),
                                          border: Border.all(
                                            color: enabled
                                                ? AppTheme.primaryTeal
                                                    .withValues(alpha: 0.35)
                                                : Colors.grey.shade200,
                                          ),
                                        ),
                                        child: Column(
                                          children: [
                                            Row(
                                              children: [
                                                Checkbox(
                                                  value: enabled,
                                                  onChanged: (v) {
                                                    setState(() {
                                                      _payerEnabled[pid] =
                                                          v ?? false;
                                                    });
                                                  },
                                                ),
                                                Expanded(
                                                  child: Text(
                                                    p.displayName,
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ),
                                                if (enabled)
                                                  SizedBox(
                                                    width: 130,
                                                    child: TextField(
                                                      controller:
                                                          _payerAmountCtrls[
                                                              pid],
                                                      keyboardType:
                                                          const TextInputType
                                                              .numberWithOptions(
                                                        decimal: true,
                                                      ),
                                                      onChanged: (_) =>
                                                          setState(() {}),
                                                      decoration:
                                                          InputDecoration(
                                                        isDense: true,
                                                        labelText:
                                                            '折算 $_currency',
                                                        prefixText:
                                                            MoneyFormatter
                                                                .symbolOf(
                                                                    _currency),
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                            if (enabled)
                                              Wrap(
                                                spacing: 8,
                                                runSpacing: 8,
                                                crossAxisAlignment:
                                                    WrapCrossAlignment.center,
                                                children: [
                                                  FilterChip(
                                                    label: const Text(
                                                      '外币卡实付折算',
                                                      style: TextStyle(
                                                          fontSize: 12),
                                                    ),
                                                    selected: useForeign,
                                                    onSelected: (v) {
                                                      setState(() =>
                                                          _payerUseForeign[
                                                              pid] = v);
                                                    },
                                                  ),
                                                  if (useForeign) ...[
                                                    DropdownButton<String>(
                                                      value: _payerForeignCurr[
                                                          pid],
                                                      items: snap
                                                          .currencies.keys
                                                          .map((c) =>
                                                              DropdownMenuItem(
                                                                  value: c,
                                                                  child:
                                                                      Text(c)))
                                                          .toList(),
                                                      onChanged: (currency) {
                                                        if (currency == null) {
                                                          return;
                                                        }
                                                        _payerForeignCurr[pid] =
                                                            currency;
                                                        _payerFxNumCtrls[pid]
                                                            ?.clear();
                                                        _payerForeignAmtCtrls[
                                                                pid]
                                                            ?.clear();
                                                        _recalcForeignPayer(
                                                            pid);
                                                      },
                                                    ),
                                                    SizedBox(
                                                      width: 130,
                                                      child: TextField(
                                                        controller:
                                                            _payerForeignAmtCtrls[
                                                                pid],
                                                        keyboardType:
                                                            const TextInputType
                                                                .numberWithOptions(
                                                          decimal: true,
                                                        ),
                                                        onChanged: (_) =>
                                                            _recalcForeignPayer(
                                                                pid),
                                                        decoration:
                                                            InputDecoration(
                                                          isDense: true,
                                                          labelText:
                                                              '实付 ${_payerForeignCurr[pid]}',
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    SizedBox(
                                                      width: 170,
                                                      child: TextField(
                                                        controller:
                                                            _payerFxNumCtrls[
                                                                pid],
                                                        keyboardType:
                                                            TextInputType.text,
                                                        onChanged: (_) =>
                                                            _recalcForeignPayer(
                                                                pid),
                                                        decoration:
                                                            const InputDecoration(
                                                          isDense: true,
                                                          labelText:
                                                              '冻结汇率（1 原币）',
                                                          hintText:
                                                              '0.0525 或 21/400',
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                          ],
                                        ),
                                      );
                                    }),
                                  ],
                                ),
                        ),
                        const SizedBox(height: 20),

                        // 4. 谁参与分摊？
                        Row(
                          children: [
                            const Text(
                              '怎么分摊',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.deepSlate,
                              ),
                            ),
                            const Spacer(),
                            if (_splitKind == SplitModeKind.equal)
                              TextButton(
                                onPressed: () {
                                  setState(() {
                                    if (_equalParticipants.length ==
                                        _participants.length) {
                                      _equalParticipants.clear();
                                    } else {
                                      _equalParticipants.addAll(
                                        _participants
                                            .map((p) => p.participantId),
                                      );
                                    }
                                  });
                                },
                                child: Text(
                                  _equalParticipants.length ==
                                          _participants.length
                                      ? '取消全选'
                                      : '全员平摊',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                          ],
                        ),
                        SegmentedButton<SplitModeKind>(
                          segments: SplitModeKind.values
                              .map(
                                (k) => ButtonSegment(
                                  value: k,
                                  label: Text(k.label),
                                ),
                              )
                              .toList(),
                          selected: {_splitKind},
                          onSelectionChanged: (s) {
                            HapticFeedback.selectionClick();
                            setState(() => _splitKind = s.first);
                          },
                        ),
                        const SizedBox(height: 10),
                        AnimatedSwitcher(
                          duration: AppTheme.fastAnim,
                          child: Column(
                            key: ValueKey(_splitKind),
                            children: _participants.map((p) {
                              final pid = p.participantId;
                              final previewVal = previewShares[pid] ?? 0;
                              return ListTile(
                                dense: true,
                                contentPadding:
                                    const EdgeInsets.symmetric(horizontal: 4),
                                leading: _splitKind == SplitModeKind.equal
                                    ? Checkbox(
                                        value: _equalParticipants.contains(pid),
                                        onChanged: (v) {
                                          HapticFeedback.selectionClick();
                                          setState(() {
                                            if (v == true) {
                                              _equalParticipants.add(pid);
                                            } else {
                                              _equalParticipants.remove(pid);
                                            }
                                          });
                                        },
                                      )
                                    : CircleAvatar(
                                        radius: 14,
                                        backgroundColor: AppTheme.primaryTeal
                                            .withValues(alpha: 0.12),
                                        child: Text(
                                          pid,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: AppTheme.primaryTeal,
                                          ),
                                        ),
                                      ),
                                title: Text(
                                  p.displayName,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600),
                                ),
                                subtitle: Text(
                                  '分摊 ${MoneyFormatter.formatMinor(previewVal, _currency, decimals: _decimals)}',
                                  style: TextStyle(
                                    color: previewVal > 0
                                        ? AppTheme.primaryTeal
                                        : Colors.grey,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                trailing: _buildSplitInputTrailing(pid),
                              );
                            }).toList(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _noteCtrl,
                          decoration: const InputDecoration(
                            labelText: '账单备注（选填）',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                        if (widget.existingExpense != null ||
                            widget.overrideParentRevisionIds != null) ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: _reasonCtrl,
                            decoration: const InputDecoration(
                              labelText: '修改原因（写入不可变修订历史）',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  // 5. 底部轻量守恒提示与确认按钮
                  Container(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border:
                          Border(top: BorderSide(color: Colors.grey.shade200)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (totalMinor > 0 && !isBalanced)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              sumPaid != totalMinor
                                  ? '垫付合计 (${MoneyFormatter.formatMinor(sumPaid, _currency, decimals: _decimals)}) 与账单总额还差 ${MoneyFormatter.formatMinor((totalMinor - sumPaid).abs(), _currency, decimals: _decimals)}'
                                  : '分摊合计 (${MoneyFormatter.formatMinor(sumShares, _currency, decimals: _decimals)}) 与账单总额还差 ${MoneyFormatter.formatMinor((totalMinor - sumShares).abs(), _currency, decimals: _decimals)}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.debtRose,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        FilledButton.icon(
                          onPressed:
                              isBalanced && _titleCtrl.text.trim().isNotEmpty
                                  ? () {
                                      HapticFeedback.lightImpact();
                                      _submit(context, payers);
                                    }
                                  : null,
                          icon: const Icon(
                            Icons.check_circle_outline,
                            size: 19,
                          ),
                          label: Text(
                            isBalanced
                                ? '保存账单 (${MoneyFormatter.formatMinor(totalMinor, _currency, decimals: _decimals)})'
                                : '请填写名称与平衡金额',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showAddCustomCategorySheet(BuildContext context) async {
    String selectedEmoji = '🎿';
    final emojiCtrl = TextEditingController(text: selectedEmoji);
    final nameCtrl = TextEditingController();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                18,
                20,
                MediaQuery.of(ctx).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '新增自定义分类',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      SizedBox(
                        width: 76,
                        child: TextField(
                          controller: emojiCtrl,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 24),
                          onChanged: (val) {
                            if (val.trim().isNotEmpty) {
                              setSheetState(() => selectedEmoji = val.trim());
                            }
                          },
                          decoration: const InputDecoration(
                            labelText: '图标',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: nameCtrl,
                          autofocus: true,
                          decoration: const InputDecoration(
                            labelText: '分类名称 (如：滑雪租板 / 居酒屋 / 伴手礼)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    '点选图标（也可直接在左侧输入框用键盘输入任意 Emoji）',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.mutedSlate,
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 168,
                    child: GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 6,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                      ),
                      itemCount: _travelEmojiPalette.length,
                      itemBuilder: (ctx, idx) {
                        final emoji = _travelEmojiPalette[idx];
                        final isSelected = selectedEmoji == emoji;
                        return InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            HapticFeedback.selectionClick();
                            setSheetState(() {
                              selectedEmoji = emoji;
                              emojiCtrl.text = emoji;
                            });
                          },
                          child: Container(
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? AppTheme.primaryTeal.withValues(alpha: 0.16)
                                  : AppTheme.surfaceBg,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isSelected
                                    ? AppTheme.primaryTeal
                                    : Colors.transparent,
                                width: 1.5,
                              ),
                            ),
                            child: Text(
                              emoji,
                              style: const TextStyle(fontSize: 22),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () async {
                        final cleanName = nameCtrl.text.trim();
                        final cleanEmoji = emojiCtrl.text.trim().isEmpty
                            ? '🏷️'
                            : emojiCtrl.text.trim();
                        if (cleanName.isEmpty) return;

                        final ok = await widget.controller.addCustomCategory(
                          icon: cleanEmoji,
                          name: cleanName,
                        );
                        if (ok && ctx.mounted) {
                          final addedCat = widget
                              .controller.snapshot!.allCategories
                              .where((c) => c.name == cleanName)
                              .firstOrNull;
                          if (addedCat != null) {
                            _toggleCategorySelection(
                              addedCat,
                              widget.controller.snapshot!.allCategories,
                            );
                          }
                          Navigator.of(ctx).pop();
                        }
                      },
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('保存并选中该分类'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _confirmDeleteCustomCategory(ExpenseCategoryModel cat) async {
    HapticFeedback.mediumImpact();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除自定义分类'),
        content: Text('确定要删除自定义分类「${cat.icon} ${cat.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      if (_selectedCategoryId == cat.id) {
        final allCategories = widget.controller.snapshot!.allCategories;
        _toggleCategorySelection(cat, allCategories);
      }
      await widget.controller.removeCustomCategory(cat.id);
    }
  }

  void _recalcForeignPayer(String pid) {
    final snap = widget.controller.snapshot!;
    final origCurr = _payerForeignCurr[pid] ?? 'USD';
    final origAmt = MoneyFormatter.parseMajorToMinor(
        _payerForeignAmtCtrls[pid]?.text ?? '', snap.decimalsOf(origCurr));
    final rate = FxRateSpecModel.parse(
        origCurr, _currency, _payerFxNumCtrls[pid]?.text ?? '');
    final converted = origAmt == null
        ? null
        : rate?.convertMinor(origAmt, snap.decimalsOf(origCurr), _decimals);
    _payerAmountCtrls[pid]?.text = converted == null
        ? ''
        : MoneyFormatter.formatMinor(converted, _currency,
                decimals: _decimals, withSymbol: false)
            .replaceAll(',', '');
    setState(() {});
  }

  Widget? _buildSplitInputTrailing(String pid) {
    switch (_splitKind) {
      case SplitModeKind.equal:
        return null;
      case SplitModeKind.exactAmounts:
        return SizedBox(
          width: 110,
          child: TextField(
            controller: _exactShareCtrls[pid],
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              labelText: '金额',
              prefixText: MoneyFormatter.symbolOf(_currency),
            ),
          ),
        );
      case SplitModeKind.ratios:
      case SplitModeKind.weights:
        return SizedBox(
          width: 88,
          child: TextField(
            controller: _weightCtrls[pid],
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              labelText: _splitKind == SplitModeKind.ratios ? '比例' : '权重',
            ),
          ),
        );
    }
  }

  Future<void> _submit(
    BuildContext context,
    List<PayerContributionModel> payers,
  ) async {
    final existing = widget.existingExpense;
    final expenseId =
        existing?.expenseId ?? 'exp_${DateTime.now().millisecondsSinceEpoch}';
    final parentIds = widget.overrideParentRevisionIds ??
        (existing?.activeRevisionEventId != null
            ? [existing!.activeRevisionEventId!]
            : const <String>[]);

    late final SplitRuleModel rule;
    switch (_splitKind) {
      case SplitModeKind.equal:
        final sorted = _equalParticipants.toList()..sort();
        rule = SplitRuleModel(
          kind: SplitModeKind.equal,
          equalParticipants: sorted,
        );
        break;
      case SplitModeKind.exactAmounts:
        rule = SplitRuleModel(
          kind: SplitModeKind.exactAmounts,
          exactShares: _previewShares(),
        );
        break;
      case SplitModeKind.ratios:
        final map = <String, int>{};
        for (final e in _weightCtrls.entries) {
          final v = int.tryParse(e.value.text.trim()) ?? 0;
          if (v > 0) map[e.key] = v;
        }
        rule = SplitRuleModel(kind: SplitModeKind.ratios, ratios: map);
        break;
      case SplitModeKind.weights:
        final map = <String, int>{};
        for (final e in _weightCtrls.entries) {
          final v = int.tryParse(e.value.text.trim()) ?? 0;
          if (v > 0) map[e.key] = v;
        }
        rule = SplitRuleModel(kind: SplitModeKind.weights, weights: map);
        break;
    }

    final snap = widget.controller.snapshot!;
    final category = _selectedCategoryId == null ? null : [
      ...snap.allCategories,
      if (_initialCategory != null) _initialCategory!,
    ].firstWhere((c) => c.id == _selectedCategoryId);
    final ok = await widget.controller.upsertExpense(
      expenseId: expenseId,
      parentRevisionEventIds: parentIds,
      currency: _currency,
      totalMinor: _totalMinor,
      payers: payers,
      splitRule: rule,
      title: _titleCtrl.text.trim(),
      note: _noteCtrl.text.trim(),
      revisionReason: _reasonCtrl.text.trim(),
      voided: false,
      details: ExpenseDetailsModel(occurredAtMs: _occurredAt?.toUtc().millisecondsSinceEpoch, category: category),
    );

    if (ok && context.mounted) {
      Navigator.of(context).pop(true);
    }
  }
}

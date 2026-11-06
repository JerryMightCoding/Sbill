import 'package:flutter/material.dart';
import '../../models/ledger_models.dart';
import '../../models/expense_list_options.dart';

class ExpenseListOptionsSheet extends StatefulWidget {
  const ExpenseListOptionsSheet({super.key, required this.snapshot, required this.initial});
  final UiWorkspaceSnapshotModel snapshot;
  final ExpenseListOptions initial;
  @override
  State<ExpenseListOptionsSheet> createState() => _ExpenseListOptionsSheetState();
}

class _ExpenseListOptionsSheetState extends State<ExpenseListOptionsSheet> {
  late ExpenseOrder _order;
  late ExpenseGrouping _grouping;
  DateTime? _from, _until;
  late Set<String?> _categories;
  late Set<String> _payers, _bearers;
  late String _currency;
  late TextEditingController _min, _max;
  String? _error;

  @override
  void initState() {
    super.initState();
    final options = widget.initial;
    _order = options.order;
    _grouping = options.grouping;
    _from = options.from;
    _until = options.until;
    _categories = {...options.categoryIds};
    _payers = {...options.payerIds};
    _bearers = {...options.bearerIds};
    _currency = options.amountCurrency ?? widget.snapshot.settlementCurrency;
    String amount(int? value) => value == null ? '' : MoneyFormatter.formatMinor(
      value, _currency, decimals: widget.snapshot.decimalsOf(_currency), withSymbol: false).replaceAll(',', '');
    _min = TextEditingController(text: amount(options.minMinor));
    _max = TextEditingController(text: amount(options.maxMinor));
  }

  @override
  void dispose() { _min.dispose(); _max.dispose(); super.dispose(); }

  Future<void> _date(bool start) async {
    final current = (start ? _from : _until) ?? DateTime.now();
    final value = await showDatePicker(context: context, initialDate: current,
      firstDate: DateTime(1), lastDate: DateTime(9999, 12, 31),
      helpText: start ? '筛选起始日期' : '筛选结束日期', cancelText: '取消', confirmText: '确定');
    if (value != null && mounted) setState(() { if (start) { _from = value; } else { _until = value; } _error = null; });
  }

  void _apply() {
    final decimals = widget.snapshot.decimalsOf(_currency);
    final min = _min.text.trim().isEmpty ? null : MoneyFormatter.parseMajorToMinor(_min.text, decimals);
    final max = _max.text.trim().isEmpty ? null : MoneyFormatter.parseMajorToMinor(_max.text, decimals);
    if ((_min.text.trim().isNotEmpty && min == null) || (_max.text.trim().isNotEmpty && max == null)) {
      setState(() => _error = '金额必须非负，符合 $_currency 小数位且不超范围'); return;
    }
    if (min != null && max != null && min > max) {
      setState(() => _error = '最低金额不能大于最高金额'); return;
    }
    if (_from != null && _until != null && _from!.isAfter(_until!)) {
      setState(() => _error = '起始日期不能晚于结束日期'); return;
    }
    Navigator.of(context).pop(ExpenseListOptions(order: _order, grouping: _grouping,
      from: _from, until: _until, categoryIds: Set.unmodifiable(_categories),
      amountCurrency: _currency, minMinor: min, maxMinor: max,
      payerIds: Set.unmodifiable(_payers), bearerIds: Set.unmodifiable(_bearers)));
  }

  Widget _heading(String title) => Padding(padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)));
  Widget _members(Set<String> selected) => Wrap(spacing: 8, children: [
    for (final person in widget.snapshot.participants)
      FilterChip(label: Text(person.displayName), selected: selected.contains(person.participantId),
        onSelected: (value) => setState(() { if (value) { selected.add(person.participantId); } else { selected.remove(person.participantId); } })),
  ]);

  @override
  Widget build(BuildContext context) => SafeArea(child: Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SizedBox(height: MediaQuery.sizeOf(context).height * .86, child: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 16, 8, 8), child: Row(children: [
        const Expanded(child: Text('排序、分组与筛选', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
        IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close)),
      ])),
      Expanded(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
        DropdownButtonFormField<ExpenseOrder>(key: const ValueKey('expense_order'), initialValue: _order,
          isExpanded: true, decoration: const InputDecoration(labelText: '排序（选择分组时按组内排序）'),
          items: [for (final order in ExpenseOrder.values) DropdownMenuItem(value: order, child: Text(order.label))],
          onChanged: (value) { if (value != null) setState(() => _order = value); }),
        const SizedBox(height: 12),
        DropdownButtonFormField<ExpenseGrouping>(key: const ValueKey('expense_grouping'), initialValue: _grouping,
          decoration: const InputDecoration(labelText: '分组方式'),
          items: [for (final group in ExpenseGrouping.values) DropdownMenuItem(value: group, child: Text(group.label))],
          onChanged: (value) { if (value != null) setState(() => _grouping = value); }),
        const SizedBox(height: 8),
        const Text('时间使用本机时区。日期组按新到旧（旧到新排序时反向）；金额只在同币种内比较，跨币种先按币种排列。', style: TextStyle(fontSize: 12)),
        _heading('时间范围（含起止两天，可选未来日期）'),
        for (final start in [true, false]) Row(children: [
          Expanded(child: OutlinedButton(onPressed: () => _date(start), child: Text(
            (start ? _from : _until) == null ? (start ? '起始日期' : '结束日期') : expenseDateLabel((start ? _from : _until)!)))),
          IconButton(onPressed: () => setState(() { if (start) { _from = null; } else { _until = null; } }), icon: const Icon(Icons.clear), tooltip: '清除日期'),
        ]),
        _heading('账单分类（可多选）'),
        Wrap(spacing: 8, children: [
          FilterChip(label: const Text('未分类'), selected: _categories.contains(null),
            onSelected: (value) => setState(() { if (value) { _categories.add(null); } else { _categories.remove(null); } })),
          for (final category in expenseFilterCategories(widget.snapshot))
            FilterChip(label: Text('${category.icon} ${category.name}'), selected: _categories.contains(category.id),
              onSelected: (value) => setState(() { if (value) { _categories.add(category.id); } else { _categories.remove(category.id); } })),
        ]),
        _heading('金额区间（账单总额，包含边界）'),
        DropdownButtonFormField<String>(initialValue: _currency,
          decoration: const InputDecoration(labelText: '金额币种（按原币，不自动折算）'),
          items: [for (final currency in widget.snapshot.currencies.keys) DropdownMenuItem(value: currency, child: Text(currency))],
          onChanged: (value) { if (value != null) setState(() { _currency = value; _min.clear(); _max.clear(); _error = null; }); }),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: TextField(key: const ValueKey('expense_min_amount'), controller: _min,
            keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '最低金额'))),
          const SizedBox(width: 12),
          Expanded(child: TextField(key: const ValueKey('expense_max_amount'), controller: _max,
            keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '最高金额'))),
        ]),
        _heading('付款人包含（匹配任一，实付金额大于 0）'),
        _members(_payers),
        _heading('成本承担人包含（匹配任一，承担金额大于 0）'),
        _members(_bearers),
        const SizedBox(height: 12),
        const Text('不同筛选条件取交集。只影响账单展示，不改变账本、余额或结算；无日期旧账不匹配日期范围，冲突账单按当前展示分支筛选。', style: TextStyle(fontSize: 12)),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Colors.red))),
      ]))),
      Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 12), child: Row(children: [
        TextButton(onPressed: () => Navigator.of(context).pop(const ExpenseListOptions()), child: const Text('重置全部')),
        const Spacer(),
        FilledButton(key: const ValueKey('apply_expense_options'), onPressed: _apply, child: const Text('应用')),
      ])),
    ])),
  ));
}

import 'ledger_models.dart';

enum ExpenseOrder {
  newest('时间：新到旧'), oldest('时间：旧到新'),
  largest('金额：高到低（同币种）'), smallest('金额：低到高（同币种）'),
  title('标题');
  const ExpenseOrder(this.label);
  final String label;
}

enum ExpenseGrouping {
  date('按日期'), category('按分类'), currency('按币种'), none('不分组');
  const ExpenseGrouping(this.label);
  final String label;
}

String expenseDateLabel(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${const ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'][date.weekday - 1]}';
String expenseTimeLabel(DateTime date) =>
    '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

ExpenseCategoryModel? expenseCategoryOf(
    ExpenseRevisionModel revision, List<ExpenseCategoryModel> catalog) {
  if (revision.details != null) return revision.details!.category;
  final candidates = [...catalog]..sort((a, b) => b.name.length.compareTo(a.name.length));
  for (final category in candidates) {
    for (final prefix in [category.name, '${category.icon} ${category.name}']) {
      if (revision.title == prefix || revision.title.startsWith('$prefix · ')) return category;
    }
  }
  return null;
}

List<ExpenseCategoryModel> expenseFilterCategories(UiWorkspaceSnapshotModel snap) {
  final categories = {for (final category in snap.allCategories) category.id: category};
  for (final item in snap.expenses) {
    final category = expenseCategoryOf(item.displayRevision, snap.allCategories);
    if (category != null) categories.putIfAbsent(category.id, () => category);
  }
  return categories.values.toList()..sort((a, b) => a.name.compareTo(b.name));
}

class ExpenseListSection {
  const ExpenseListSection(this.label, this.expenses);
  final String? label;
  final List<UiExpenseViewModel> expenses;

  Map<String, int> totalsByCurrency() {
    final totals = <String, int>{};
    for (final expense in expenses) {
      final revision = expense.displayRevision;
      if (revision.voided) {
        continue;
      }
      totals.update(revision.currency, (v) => v + revision.totalMinor, ifAbsent: () => revision.totalMinor);
    }
    return totals;
  }

  String subtotalLabel(int Function(String currency) decimalsOf) {
    final totals = totalsByCurrency();
    if (totals.isEmpty) {
      return '小计 0';
    }
    final currencies = totals.keys.toList()..sort();
    final parts = currencies.map((currency) => MoneyFormatter.formatMinor(
          totals[currency]!,
          currency,
          decimals: decimalsOf(currency),
        ));
    return '小计 ${parts.join(' + ')}';
  }
}

class ExpenseListOptions {
  const ExpenseListOptions({
    this.order = ExpenseOrder.newest, this.grouping = ExpenseGrouping.date,
    this.from, this.until, this.categoryIds = const {},
    this.amountCurrency, this.minMinor, this.maxMinor,
    this.payerIds = const {}, this.bearerIds = const {},
  });
  final ExpenseOrder order;
  final ExpenseGrouping grouping;
  final DateTime? from;
  final DateTime? until;
  final Set<String?> categoryIds;
  final String? amountCurrency;
  final int? minMinor;
  final int? maxMinor;
  final Set<String> payerIds;
  final Set<String> bearerIds;

  int get filterCount => (from != null || until != null ? 1 : 0) +
      (categoryIds.isNotEmpty ? 1 : 0) + (minMinor != null || maxMinor != null ? 1 : 0) +
      (payerIds.isNotEmpty ? 1 : 0) + (bearerIds.isNotEmpty ? 1 : 0);

  bool matches(UiExpenseViewModel expense, List<ExpenseCategoryModel> catalog) {
    final revision = expense.displayRevision;
    final time = revision.details?.localTime;
    if (from != null || until != null) {
      if (time == null) return false;
      if (from != null && time.isBefore(DateTime(from!.year, from!.month, from!.day))) return false;
      if (until != null && !time.isBefore(DateTime(until!.year, until!.month, until!.day + 1))) return false;
    }
    if (categoryIds.isNotEmpty && !categoryIds.contains(expenseCategoryOf(revision, catalog)?.id)) return false;
    if (minMinor != null || maxMinor != null) {
      if (amountCurrency == null || revision.currency != amountCurrency) return false;
      if (minMinor != null && revision.totalMinor < minMinor!) return false;
      if (maxMinor != null && revision.totalMinor > maxMinor!) return false;
    }
    if (payerIds.isNotEmpty && !revision.payers.any((p) => p.amountMinor > 0 && payerIds.contains(p.participantId))) return false;
    if (bearerIds.isNotEmpty && !revision.resolvedShares.entries.any((share) => share.value > 0 && bearerIds.contains(share.key))) return false;
    return true;
  }

  int _compare(UiExpenseViewModel a, UiExpenseViewModel b) {
    final x = a.displayRevision;
    final y = b.displayRevision;
    int result;
    switch (order) {
      case ExpenseOrder.newest:
      case ExpenseOrder.oldest:
        final xt = x.details?.occurredAtMs;
        final yt = y.details?.occurredAtMs;
        if (xt == null || yt == null) {
          result = xt == yt ? 0 : xt == null ? 1 : -1;
        } else {
          result = order == ExpenseOrder.newest ? yt.compareTo(xt) : xt.compareTo(yt);
        }
        break;
      case ExpenseOrder.largest:
      case ExpenseOrder.smallest:
        result = x.currency.compareTo(y.currency);
        if (result == 0) result = order == ExpenseOrder.largest ? y.totalMinor.compareTo(x.totalMinor) : x.totalMinor.compareTo(y.totalMinor);
        break;
      case ExpenseOrder.title:
        result = x.title.compareTo(y.title);
        break;
    }
    return result != 0 ? result : a.expenseId.compareTo(b.expenseId);
  }

  List<ExpenseListSection> sections(Iterable<UiExpenseViewModel> expenses,
      List<ExpenseCategoryModel> catalog) {
    final sorted = expenses.where((e) => matches(e, catalog)).toList()..sort(_compare);
    if (sorted.isEmpty) return [];
    if (grouping == ExpenseGrouping.none) return [ExpenseListSection(null, sorted)];
    final grouped = <String, List<UiExpenseViewModel>>{};
    final labels = <String, String>{};
    for (final expense in sorted) {
      final revision = expense.displayRevision;
      late String key;
      late String label;
      switch (grouping) {
        case ExpenseGrouping.date:
          final time = revision.details?.localTime;
          label = time == null ? '未记录日期' : expenseDateLabel(time);
          key = time == null ? '' : label.split(' ').first;
          break;
        case ExpenseGrouping.category:
          final category = expenseCategoryOf(revision, catalog);
          key = category?.id ?? '';
          label = category == null ? '未分类' : '${category.icon} ${category.name}';
          break;
        case ExpenseGrouping.currency:
          key = revision.currency;
          label = revision.currency;
          break;
        case ExpenseGrouping.none:
          throw StateError('不分组已单独处理');
      }
      grouped.putIfAbsent(key, () => []).add(expense);
      labels[key] = label;
    }
    final keys = grouped.keys.toList()..sort((a, b) {
      if (a.isEmpty || b.isEmpty) return a == b ? 0 : a.isEmpty ? 1 : -1;
      if (grouping == ExpenseGrouping.date) return order == ExpenseOrder.oldest ? a.compareTo(b) : b.compareTo(a);
      return labels[a]!.compareTo(labels[b]!);
    });
    return keys.map((key) => ExpenseListSection(labels[key], grouped[key]!)).toList();
  }
}

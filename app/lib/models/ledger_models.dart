import 'package:flutter/foundation.dart';

@immutable
class LedgerSummary {
  const LedgerSummary(
      {required this.groupId, required this.groupName, required this.legacy});
  final String groupId;
  final String groupName;
  final bool legacy;
  factory LedgerSummary.fromJson(Map<String, dynamic> json) => LedgerSummary(
        groupId: json['group_id'] as String,
        groupName: json['group_name'] as String,
        legacy: json['legacy'] as bool? ?? false,
      );
}

enum MemberRole {
  owner('Owner', '群主'),
  financeEditor('FinanceEditor', '财务管理员'),
  member('Member', '普通成员'),
  viewer('Viewer', '只读成员');

  const MemberRole(this.wireName, this.label);
  final String wireName;
  final String label;

  static MemberRole fromWire(String raw) {
    return MemberRole.values.firstWhere(
      (r) => r.wireName == raw,
      orElse: () => MemberRole.member,
    );
  }

  bool get canEditAnyBill =>
      this == MemberRole.owner || this == MemberRole.financeEditor;

  bool get canPublishSettlement =>
      this == MemberRole.owner || this == MemberRole.financeEditor;

  bool get canManageMembers => this == MemberRole.owner;
}

enum SettlementModeOption {
  byCurrencyPairwise(
    'ByCurrencyPairwise',
    '按币种 · 一对一',
    '每种币种独立核算，保留原始债权关系，仅同对双向抵消',
    false,
    false,
  ),
  byCurrencyMinTransfers(
    'ByCurrencyMinTransfers',
    '按币种 · 最少次数',
    '每种币种分别按净余额求最少转账次数 (Bitmask DP)，不跨币种抵消',
    false,
    true,
  ),
  mergedCurrencyPairwise(
    'MergedCurrencyPairwise',
    '合并币种 · 一对一',
    '按冻结结算汇率折算为单一结算币种，保留各对成员债权不经第三人重排',
    true,
    false,
  ),
  mergedCurrencyMinTransfers(
    'MergedCurrencyMinTransfers',
    '合并币种 · 最少次数',
    '折算为单一结算币种后，按全组净余额求全局最少转账次数',
    true,
    true,
  );

  const SettlementModeOption(
    this.wireName,
    this.label,
    this.description,
    this.mergeCurrency,
    this.simplifyTransfers,
  );

  final String wireName;
  final String label;
  final String description;
  final bool mergeCurrency;
  final bool simplifyTransfers;

  static SettlementModeOption fromSwitches({
    required bool mergeCurrency,
    required bool simplifyTransfers,
  }) {
    if (!mergeCurrency && !simplifyTransfers) {
      return SettlementModeOption.byCurrencyPairwise;
    }
    if (!mergeCurrency && simplifyTransfers) {
      return SettlementModeOption.byCurrencyMinTransfers;
    }
    if (mergeCurrency && !simplifyTransfers) {
      return SettlementModeOption.mergedCurrencyPairwise;
    }
    return SettlementModeOption.mergedCurrencyMinTransfers;
  }

  static SettlementModeOption fromWire(String raw) {
    return SettlementModeOption.values.firstWhere(
      (m) => m.wireName == raw,
      orElse: () => SettlementModeOption.byCurrencyPairwise,
    );
  }
}

@immutable
class ExpenseCategoryModel {
  const ExpenseCategoryModel({
    required this.id,
    required this.icon,
    required this.name,
    required this.isCustom,
  });

  final String id;
  final String icon;
  final String name;
  final bool isCustom;

  Map<String, dynamic> toJson() => {
    'id': id, 'icon': icon, 'name': name, 'is_custom': isCustom,
  };

  static const List<ExpenseCategoryModel> presetCategories = [
    ExpenseCategoryModel(
      id: 'preset_hotel',
      icon: '🏨',
      name: '酒店住宿',
      isCustom: false,
    ),
    ExpenseCategoryModel(
      id: 'preset_dining',
      icon: '🍜',
      name: '餐厅用餐',
      isCustom: false,
    ),
    ExpenseCategoryModel(
      id: 'preset_transport',
      icon: '🚄',
      name: '交通包车',
      isCustom: false,
    ),
    ExpenseCategoryModel(
      id: 'preset_ticket',
      icon: '🎫',
      name: '景区门票',
      isCustom: false,
    ),
    ExpenseCategoryModel(
      id: 'preset_shopping',
      icon: '🛍️',
      name: '超市补给',
      isCustom: false,
    ),
  ];

  factory ExpenseCategoryModel.fromJson(Map<String, dynamic> json) {
    return ExpenseCategoryModel(
      id: json['id'] as String,
      icon: json['icon'] as String,
      name: json['name'] as String,
      isCustom: json['is_custom'] as bool? ?? true,
    );
  }
}

@immutable
class CurrencySpecModel {
  const CurrencySpecModel({
    required this.code,
    required this.minorDecimals,
  });

  final String code;
  final int minorDecimals;

  factory CurrencySpecModel.fromJson(Map<String, dynamic> json) {
    return CurrencySpecModel(
      code: json['code'] as String,
      minorDecimals: (json['minor_decimals'] as num).toInt(),
    );
  }
}

@immutable
class ParticipantModel {
  const ParticipantModel({
    required this.participantId,
    required this.displayName,
    required this.boundPublicKey,
    required this.role,
    required this.active,
  });

  final String participantId;
  final String displayName;
  final String? boundPublicKey;
  final MemberRole role;
  final bool active;

  bool get hasBoundDevice =>
      boundPublicKey != null && boundPublicKey!.isNotEmpty;

  factory ParticipantModel.fromJson(Map<String, dynamic> json) {
    return ParticipantModel(
      participantId: json['participant_id'] as String,
      displayName: json['display_name'] as String,
      boundPublicKey: json['bound_public_key'] as String?,
      role: MemberRole.fromWire(json['role'] as String),
      active: json['active'] as bool? ?? true,
    );
  }
}

@immutable
class FxRateSpecModel {
  const FxRateSpecModel({
    required this.baseCurrency,
    required this.quoteCurrency,
    required this.numerator,
    required this.denominator,
  });

  final String baseCurrency;
  final String quoteCurrency;
  final int numerator;
  final int denominator;

  String get inputText =>
      denominator == 1 ? numerator.toString() : '$numerator/$denominator';

  static FxRateSpecModel? parse(String base, String quote, String raw) {
    final text = raw.trim();
    if (text.length > 80) return null;
    BigInt numerator;
    BigInt denominator;
    if (RegExp(r'^\d+\s*/\s*\d+$').hasMatch(text)) {
      final parts = text.split('/');
      numerator = BigInt.parse(parts[0].trim());
      denominator = BigInt.parse(parts[1].trim());
    } else if (RegExp(r'^\d+(\.\d{1,18})?$').hasMatch(text)) {
      final parts = text.split('.');
      final fraction = parts.length == 2 ? parts[1] : '';
      numerator = BigInt.parse('${parts[0]}$fraction');
      denominator = BigInt.from(10).pow(fraction.length);
    } else {
      return null;
    }
    if (numerator <= BigInt.zero || denominator <= BigInt.zero) return null;
    final gcd = numerator.gcd(denominator);
    numerator ~/= gcd;
    denominator ~/= gcd;
    final max = BigInt.parse('9223372036854775807');
    if (numerator > max || denominator > max) return null;
    return FxRateSpecModel(
      baseCurrency: base,
      quoteCurrency: quote,
      numerator: numerator.toInt(),
      denominator: denominator.toInt(),
    );
  }

  int? convertMinor(int amount, int baseDecimals, int quoteDecimals) {
    if (numerator <= 0 ||
        denominator <= 0 ||
        baseDecimals < 0 ||
        baseDecimals > 18 ||
        quoteDecimals < 0 ||
        quoteDecimals > 18) {
      return null;
    }
    final value = BigInt.from(amount);
    final divisor =
        BigInt.from(denominator) * BigInt.from(10).pow(baseDecimals);
    final product = value.abs() *
        BigInt.from(numerator) *
        BigInt.from(10).pow(quoteDecimals);
    final rounded = (product + divisor ~/ BigInt.two) ~/ divisor;
    final result = value.isNegative ? -rounded : rounded;
    final max = BigInt.parse('9223372036854775807');
    if (result > max || result < -max - BigInt.one) return null;
    return result.toInt();
  }

  String get displayRatio => denominator == 1
      ? '1 $baseCurrency = $numerator $quoteCurrency'
      : '$denominator $baseCurrency = $numerator $quoteCurrency';

  Map<String, dynamic> toJson() => {
        'base_currency': baseCurrency,
        'quote_currency': quoteCurrency,
        'numerator': numerator,
        'denominator': denominator,
      };

  factory FxRateSpecModel.fromJson(Map<String, dynamic> json) {
    return FxRateSpecModel(
      baseCurrency: json['base_currency'] as String,
      quoteCurrency: json['quote_currency'] as String,
      numerator: (json['numerator'] as num).toInt(),
      denominator: (json['denominator'] as num).toInt(),
    );
  }
}

@immutable
class PayerContributionModel {
  const PayerContributionModel({
    required this.participantId,
    required this.amountMinor,
    this.originalCurrency,
    this.originalAmountMinor,
    this.frozenFxRate,
  });

  final String participantId;
  final int amountMinor;
  final String? originalCurrency;
  final int? originalAmountMinor;
  final FxRateSpecModel? frozenFxRate;

  Map<String, dynamic> toJson() => {
        'participant_id': participantId,
        'amount_minor': amountMinor,
        'original_currency': originalCurrency,
        'original_amount_minor': originalAmountMinor,
        'frozen_fx_rate': frozenFxRate?.toJson(),
      };

  factory PayerContributionModel.fromJson(Map<String, dynamic> json) {
    return PayerContributionModel(
      participantId: json['participant_id'] as String,
      amountMinor: (json['amount_minor'] as num).toInt(),
      originalCurrency: json['original_currency'] as String?,
      originalAmountMinor: (json['original_amount_minor'] as num?)?.toInt(),
      frozenFxRate: json['frozen_fx_rate'] != null
          ? FxRateSpecModel.fromJson(
              Map<String, dynamic>.from(json['frozen_fx_rate'] as Map),
            )
          : null,
    );
  }
}

enum SplitModeKind {
  equal('均摊'),
  exactAmounts('指定金额'),
  ratios('按比例'),
  weights('按权重');

  const SplitModeKind(this.label);
  final String label;
}

@immutable
class SplitRuleModel {
  const SplitRuleModel({
    required this.kind,
    this.equalParticipants = const [],
    this.exactShares = const {},
    this.ratios = const {},
    this.weights = const {},
  });

  final SplitModeKind kind;
  final List<String> equalParticipants;
  final Map<String, int> exactShares;
  final Map<String, int> ratios;
  final Map<String, int> weights;

  Map<String, dynamic> toJson() {
    switch (kind) {
      case SplitModeKind.equal:
        return {
          'Equal': {'participants': equalParticipants},
        };
      case SplitModeKind.exactAmounts:
        return {
          'ExactAmounts': {'shares': exactShares},
        };
      case SplitModeKind.ratios:
        return {
          'Ratios': {'ratios': ratios},
        };
      case SplitModeKind.weights:
        return {
          'Weights': {'weights': weights},
        };
    }
  }

  factory SplitRuleModel.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('Equal')) {
      final inner = Map<String, dynamic>.from(json['Equal'] as Map);
      final list = (inner['participants'] as List).cast<String>();
      return SplitRuleModel(kind: SplitModeKind.equal, equalParticipants: list);
    }
    if (json.containsKey('ExactAmounts')) {
      final inner = Map<String, dynamic>.from(json['ExactAmounts'] as Map);
      final map = Map<String, dynamic>.from(inner['shares'] as Map)
          .map((k, v) => MapEntry(k, (v as num).toInt()));
      return SplitRuleModel(kind: SplitModeKind.exactAmounts, exactShares: map);
    }
    if (json.containsKey('Ratios')) {
      final inner = Map<String, dynamic>.from(json['Ratios'] as Map);
      final map = Map<String, dynamic>.from(inner['ratios'] as Map)
          .map((k, v) => MapEntry(k, (v as num).toInt()));
      return SplitRuleModel(kind: SplitModeKind.ratios, ratios: map);
    }
    if (json.containsKey('Weights')) {
      final inner = Map<String, dynamic>.from(json['Weights'] as Map);
      final map = Map<String, dynamic>.from(inner['weights'] as Map)
          .map((k, v) => MapEntry(k, (v as num).toInt()));
      return SplitRuleModel(kind: SplitModeKind.weights, weights: map);
    }
    return const SplitRuleModel(kind: SplitModeKind.equal);
  }
}

@immutable
class ExpenseDetailsModel {
  const ExpenseDetailsModel({this.occurredAtMs, this.category});

  final int? occurredAtMs;
  final ExpenseCategoryModel? category;

  DateTime? get localTime => occurredAtMs == null ? null :
      DateTime.fromMillisecondsSinceEpoch(occurredAtMs!, isUtc: true).toLocal();

  Map<String, dynamic> toJson() => {
    'occurred_at_ms': occurredAtMs, 'category': category?.toJson(),
  };

  factory ExpenseDetailsModel.fromJson(Map<String, dynamic> json) => ExpenseDetailsModel(
    occurredAtMs: (json['occurred_at_ms'] as num?)?.toInt(),
    category: json['category'] == null ? null : ExpenseCategoryModel.fromJson(
      Map<String, dynamic>.from(json['category'] as Map)),
  );
}

@immutable
class ExpenseRevisionModel {
  const ExpenseRevisionModel({
    required this.expenseId,
    required this.parentRevisionEventIds,
    required this.currency,
    required this.totalMinor,
    required this.payers,
    required this.splitRule,
    required this.resolvedShares,
    required this.attributionMatrix,
    required this.title,
    required this.note,
    required this.revisionReason,
    required this.voided,
    this.details,
  });

  final String expenseId;
  final List<String> parentRevisionEventIds;
  final String currency;
  final int totalMinor;
  final List<PayerContributionModel> payers;
  final SplitRuleModel splitRule;
  final Map<String, int> resolvedShares;
  final Map<String, Map<String, int>> attributionMatrix;
  final String title;
  final String note;
  final String revisionReason;
  final bool voided;
  final ExpenseDetailsModel? details;

  factory ExpenseRevisionModel.fromJson(Map<String, dynamic> json) {
    final sharesRaw = Map<String, dynamic>.from(json['resolved_shares'] as Map);
    final matrixRaw =
        Map<String, dynamic>.from(json['attribution_matrix'] as Map);

    return ExpenseRevisionModel(
      expenseId: json['expense_id'] as String,
      parentRevisionEventIds:
          (json['parent_revision_event_ids'] as List).cast<String>(),
      currency: json['currency'] as String,
      totalMinor: (json['total_minor'] as num).toInt(),
      payers: (json['payers'] as List)
          .map((e) => PayerContributionModel.fromJson(
              Map<String, dynamic>.from(e as Map)))
          .toList(),
      splitRule: SplitRuleModel.fromJson(
        Map<String, dynamic>.from(json['split_rule'] as Map),
      ),
      resolvedShares: sharesRaw.map((k, v) => MapEntry(k, (v as num).toInt())),
      attributionMatrix: matrixRaw.map(
        (debtor, inner) => MapEntry(
          debtor,
          Map<String, dynamic>.from(inner as Map)
              .map((cred, amt) => MapEntry(cred, (amt as num).toInt())),
        ),
      ),
      title: json['title'] as String? ?? '',
      note: json['note'] as String? ?? '',
      revisionReason: json['revision_reason'] as String? ?? '',
      voided: json['voided'] as bool? ?? false,
      details: json['details'] == null ? null : ExpenseDetailsModel.fromJson(
        Map<String, dynamic>.from(json['details'] as Map)), 
    );
  }
}

@immutable
class UiRevisionEntryModel {
  const UiRevisionEntryModel({
    required this.eventId,
    required this.authorMemberId,
    required this.deviceId,
    required this.sequence,
    required this.payload,
  });

  final String eventId;
  final String authorMemberId;
  final String deviceId;
  final int sequence;
  final ExpenseRevisionModel payload;

  factory UiRevisionEntryModel.fromJson(Map<String, dynamic> json) {
    return UiRevisionEntryModel(
      eventId: json['event_id'] as String,
      authorMemberId: json['author_member_id'] as String,
      deviceId: json['device_id'] as String,
      sequence: (json['sequence'] as num).toInt(),
      payload: ExpenseRevisionModel.fromJson(
        Map<String, dynamic>.from(json['payload'] as Map),
      ),
    );
  }
}

@immutable
class UiExpenseViewModel {
  const UiExpenseViewModel({
    required this.expenseId,
    required this.creatorMemberId,
    required this.hasConflict,
    required this.isSettledInPriorCommit,
    required this.activeRevisionEventId,
    required this.activeRevision,
    required this.conflictBranches,
    required this.history,
  });

  final String expenseId;
  final String creatorMemberId;
  final bool hasConflict;
  final bool isSettledInPriorCommit;
  final String? activeRevisionEventId;
  final ExpenseRevisionModel? activeRevision;
  final List<UiRevisionEntryModel> conflictBranches;
  final List<UiRevisionEntryModel> history;

  ExpenseRevisionModel get displayRevision =>
      activeRevision ??
      (conflictBranches.isNotEmpty
          ? conflictBranches.first.payload
          : history.last.payload);

  factory UiExpenseViewModel.fromJson(Map<String, dynamic> json) {
    return UiExpenseViewModel(
      expenseId: json['expense_id'] as String,
      creatorMemberId: json['creator_member_id'] as String,
      hasConflict: json['has_conflict'] as bool? ?? false,
      isSettledInPriorCommit:
          json['is_settled_in_prior_commit'] as bool? ?? false,
      activeRevisionEventId: json['active_revision_event_id'] as String?,
      activeRevision: json['active_revision'] != null
          ? ExpenseRevisionModel.fromJson(
              Map<String, dynamic>.from(json['active_revision'] as Map),
            )
          : null,
      conflictBranches: (json['conflict_branches'] as List)
          .map((e) => UiRevisionEntryModel.fromJson(
              Map<String, dynamic>.from(e as Map)))
          .toList(),
      history: (json['history'] as List)
          .map((e) => UiRevisionEntryModel.fromJson(
              Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }
}

@immutable
class RepaymentItemModel {
  const RepaymentItemModel({
    required this.paymentId,
    required this.declareEventId,
    required this.confirmEventId,
    required this.payerId,
    required this.payeeId,
    required this.currency,
    required this.amountMinor,
    required this.targetObligationId,
    required this.note,
    required this.statusLabel,
    required this.isConfirmed,
    required this.overpaymentMinor,
    this.isPendingMapping = false,
    this.isDisputed = false,
  });

  final String paymentId;
  final String declareEventId;
  final String? confirmEventId;
  final String payerId;
  final String payeeId;
  final String currency;
  final int amountMinor;
  final String? targetObligationId;
  final String note;
  final String statusLabel;
  final bool isConfirmed;
  final int overpaymentMinor;
  final bool isPendingMapping;
  final bool isDisputed;

  factory RepaymentItemModel.fromJson(Map<String, dynamic> json) {
    final decl = Map<String, dynamic>.from(json['declaration'] as Map);
    final rawStatus = json['status'];
    String statusLabel = '付款方已声明 (待收款方确认)';
    bool isConfirmed = false;
    bool isPendingMapping = false;
    bool isDisputed = false;
    if (rawStatus == 'ConfirmedByBoth') {
      statusLabel = '双方已确认入账';
      isConfirmed = true;
    } else if (rawStatus == 'PendingMapping') {
      statusLabel = '迟到还款 (待映射结算义务)';
      isPendingMapping = true;
    } else if (rawStatus is Map && rawStatus.containsKey('Disputed')) {
      final d = rawStatus['Disputed'];
      final reason = d is Map ? (d['reason'] as String? ?? '') : '';
      statusLabel = reason.isEmpty ? '收款方提出异议' : '收款方异议：$reason';
      isDisputed = true;
    }
    return RepaymentItemModel(
      paymentId: json['payment_id'] as String,
      declareEventId: json['declare_event_id'] as String,
      confirmEventId: json['confirm_event_id'] as String?,
      payerId: decl['payer_id'] as String,
      payeeId: decl['payee_id'] as String,
      currency: decl['currency'] as String,
      amountMinor: (decl['amount_minor'] as num).toInt(),
      targetObligationId: json['applied_to_obligation_id'] as String? ??
          decl['target_obligation_id'] as String?,
      note: decl['note'] as String? ?? '',
      statusLabel: statusLabel,
      isConfirmed: isConfirmed,
      overpaymentMinor: (json['overpayment_minor'] as num?)?.toInt() ?? 0,
      isPendingMapping: isPendingMapping,
      isDisputed: isDisputed,
    );
  }
}

@immutable
class TransferEdgeModel {
  const TransferEdgeModel({
    required this.debtorId,
    required this.creditorId,
    required this.currency,
    required this.amountMinor,
  });

  final String debtorId;
  final String creditorId;
  final String currency;
  final int amountMinor;

  factory TransferEdgeModel.fromJson(Map<String, dynamic> json) {
    return TransferEdgeModel(
      debtorId: json['debtor_id'] as String,
      creditorId: json['creditor_id'] as String,
      currency: json['currency'] as String,
      amountMinor: (json['amount_minor'] as num).toInt(),
    );
  }
}

@immutable
class SettlementObligationModel {
  const SettlementObligationModel({
    required this.obligationId,
    required this.snapshotId,
    required this.debtorId,
    required this.creditorId,
    required this.currency,
    required this.totalAmountMinor,
    required this.paidAmountMinor,
  });

  final String obligationId;
  final String snapshotId;
  final String debtorId;
  final String creditorId;
  final String currency;
  final int totalAmountMinor;
  final int paidAmountMinor;

  int get remainingMinor =>
      (totalAmountMinor - paidAmountMinor).clamp(0, totalAmountMinor);

  bool get isFullyPaid => remainingMinor == 0;

  factory SettlementObligationModel.fromJson(Map<String, dynamic> json) {
    return SettlementObligationModel(
      obligationId: json['obligation_id'] as String,
      snapshotId: json['snapshot_id'] as String,
      debtorId: json['debtor_id'] as String,
      creditorId: json['creditor_id'] as String,
      currency: json['currency'] as String,
      totalAmountMinor: (json['total_amount_minor'] as num).toInt(),
      paidAmountMinor: (json['paid_amount_minor'] as num).toInt(),
    );
  }
}

@immutable
class SnapshotProjectionModel {
  const SnapshotProjectionModel({
    required this.snapshotId,
    required this.snapshotEventId,
    required this.mode,
    required this.settlementCurrency,
    required this.transfers,
    required this.requiredApprovers,
    required this.approvedBy,
    required this.commitEventId,
    required this.statusWire,
    required this.snapshotDigest,
    required this.provenOptimal,
    this.fxRates = const [],
    this.coveredExpenseCount = 0,
    this.coveredRepaymentCount = 0,
    this.novatedObligationCount = 0,
  });

  final String snapshotId;
  final String snapshotEventId;
  final SettlementModeOption mode;
  final String? settlementCurrency;
  final List<TransferEdgeModel> transfers;
  final List<String> requiredApprovers;
  final Map<String, String> approvedBy;
  final String? commitEventId;
  final String statusWire;
  final String snapshotDigest;
  final bool provenOptimal;
  final List<FxRateSpecModel> fxRates;
  final int coveredExpenseCount;
  final int coveredRepaymentCount;
  final int novatedObligationCount;

  bool get isReadyToCommit => statusWire == 'ReadyToCommit';
  bool get isCommitted => statusWire == 'Committed';

  String get statusLabel {
    switch (statusWire) {
      case 'AwaitingApprovals':
        return '等待受影响成员签名确认 (${approvedBy.length}/${requiredApprovers.length})';
      case 'ReadyToCommit':
        return '全体受影响成员已签名 · 待协调者正式提交';
      case 'Committed':
        return '已正式提交并完成债务重组 (Debt Novation)';
      case 'SupersededOrConflicted':
        return '已被取代或存在提交链冲突';
      default:
        return statusWire;
    }
  }

  factory SnapshotProjectionModel.fromJson(Map<String, dynamic> json) {
    final snap = Map<String, dynamic>.from(json['snapshot'] as Map);
    final approvedRaw = Map<String, dynamic>.from(json['approved_by'] as Map);
    return SnapshotProjectionModel(
      snapshotId: snap['snapshot_id'] as String,
      snapshotEventId: json['snapshot_event_id'] as String,
      mode: SettlementModeOption.fromWire(snap['mode'] as String),
      settlementCurrency: snap['settlement_currency'] as String?,
      transfers: (snap['transfers'] as List)
          .map((e) =>
              TransferEdgeModel.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      requiredApprovers: (snap['required_approvers'] as List).cast<String>(),
      approvedBy: approvedRaw.map((k, v) => MapEntry(k, v as String)),
      commitEventId: json['commit_event_id'] as String?,
      statusWire: json['status'] as String,
      snapshotDigest: snap['snapshot_digest'] as String,
      provenOptimal: snap['optimality'] == 'ProvenOptimal',
      fxRates: ((snap['fx_rates'] as List?) ?? const [])
          .map((rate) =>
              FxRateSpecModel.fromJson(Map<String, dynamic>.from(rate as Map)))
          .toList(),
      coveredExpenseCount:
          (snap['covered_expense_revisions'] as Map?)?.length ?? 0,
      coveredRepaymentCount:
          (snap['covered_repayment_ids'] as List?)?.length ?? 0,
      novatedObligationCount:
          (snap['novated_obligation_ids'] as List?)?.length ?? 0,
    );
  }
}

@immutable
class UiSettlementPreviewModel {
  const UiSettlementPreviewModel({
    required this.modeKey,
    required this.settlementCurrency,
    required this.netBalancesByCurrency,
    required this.transfers,
    required this.provenOptimal,
  });

  final String modeKey;
  final String? settlementCurrency;
  final Map<String, Map<String, int>> netBalancesByCurrency;
  final List<TransferEdgeModel> transfers;
  final bool provenOptimal;

  factory UiSettlementPreviewModel.fromJson(
    String key,
    Map<String, dynamic> json,
  ) {
    final rawBalances =
        Map<String, dynamic>.from(json['net_balances_by_currency'] as Map);
    return UiSettlementPreviewModel(
      modeKey: key,
      settlementCurrency: json['settlement_currency'] as String?,
      netBalancesByCurrency: rawBalances.map(
        (curr, map) => MapEntry(
          curr,
          Map<String, dynamic>.from(map as Map)
              .map((m, v) => MapEntry(m, (v as num).toInt())),
        ),
      ),
      transfers: (json['transfers'] as List)
          .map((e) =>
              TransferEdgeModel.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      provenOptimal: json['optimality'] == 'ProvenOptimal',
    );
  }
}

@immutable
class WebDavPendingObjectModel {
  const WebDavPendingObjectModel({
    required this.objectHash,
    required this.ciphertextB64,
  });

  final String objectHash;
  final String ciphertextB64;

  factory WebDavPendingObjectModel.fromJson(Map<String, dynamic> json) {
    return WebDavPendingObjectModel(
      objectHash: json['object_hash'] as String? ?? '',
      ciphertextB64: json['ciphertext_b64'] as String? ?? '',
    );
  }
}

@immutable
class WebDavStatusModel {
  const WebDavStatusModel({
    required this.enabled,
    required this.endpointUrl,
    required this.username,
    required this.opaqueGroupDir,
    required this.simulateUnreachable,
    required this.pendingUploadCount,
    required this.remoteObjectCount,
    this.pendingUploads = const [],
  });

  final bool enabled;
  final String endpointUrl;
  final String username;
  final String opaqueGroupDir;
  final bool simulateUnreachable;
  final int pendingUploadCount;
  final int remoteObjectCount;
  final List<WebDavPendingObjectModel> pendingUploads;

  factory WebDavStatusModel.fromJson(Map<String, dynamic> json) {
    return WebDavStatusModel(
      enabled: json['enabled'] as bool? ?? true,
      endpointUrl: json['endpoint_url'] as String? ?? '',
      username: json['username'] as String? ?? '',
      opaqueGroupDir: json['opaque_group_dir'] as String? ?? '',
      simulateUnreachable: json['simulate_unreachable'] as bool? ?? false,
      pendingUploadCount: (json['pending_upload_count'] as num?)?.toInt() ?? 0,
      remoteObjectCount: (json['remote_object_count'] as num?)?.toInt() ?? 0,
      pendingUploads: ((json['pending_uploads'] as List?) ?? const [])
          .map((e) => WebDavPendingObjectModel.fromJson(
              Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }
}

@immutable
class SyncActivityReportModel {
  const SyncActivityReportModel({
    required this.channel,
    required this.summaryTitle,
    required this.addedEvents,
    required this.duplicateEvents,
    required this.rejectedOrTampered,
    required this.uploadedObjects,
    required this.failedUploads,
    required this.packageByteLen,
    this.packageDigest,
    this.exportedTripdeltaJson,
    this.exportedCompactCode,
  });

  final String channel;
  final String summaryTitle;
  final int addedEvents;
  final int duplicateEvents;
  final int rejectedOrTampered;
  final int uploadedObjects;
  final int failedUploads;
  final int packageByteLen;
  final String? packageDigest;
  final String? exportedTripdeltaJson;
  final String? exportedCompactCode;

  factory SyncActivityReportModel.fromJson(Map<String, dynamic> json) {
    return SyncActivityReportModel(
      channel: json['channel'] as String? ?? '',
      summaryTitle: json['summary_title'] as String? ?? '',
      addedEvents: (json['added_events'] as num?)?.toInt() ?? 0,
      duplicateEvents: (json['duplicate_events'] as num?)?.toInt() ?? 0,
      rejectedOrTampered: (json['rejected_or_tampered'] as num?)?.toInt() ?? 0,
      uploadedObjects: (json['uploaded_objects'] as num?)?.toInt() ?? 0,
      failedUploads: (json['failed_uploads'] as num?)?.toInt() ?? 0,
      packageByteLen: (json['package_byte_len'] as num?)?.toInt() ?? 0,
      packageDigest: json['package_digest'] as String?,
      exportedTripdeltaJson: json['exported_tripdelta_json'] as String?,
      exportedCompactCode: json['exported_compact_code'] as String?,
    );
  }
}

@immutable
class LanPeerItemModel {
  const LanPeerItemModel({
    required this.memberId,
    required this.displayName,
    required this.deviceId,
    required this.endpointAddr,
    required this.contiguousSeq,
    required this.maxSeenSeq,
    required this.missingSeqs,
  });

  final String memberId;
  final String displayName;
  final String deviceId;
  final String endpointAddr;
  final int contiguousSeq;
  final int maxSeenSeq;
  final List<int> missingSeqs;

  factory LanPeerItemModel.fromJson(Map<String, dynamic> json) {
    return LanPeerItemModel(
      memberId: json['member_id'] as String,
      displayName: json['display_name'] as String,
      deviceId: json['device_id'] as String,
      endpointAddr: json['endpoint_addr'] as String,
      contiguousSeq: (json['contiguous_seq'] as num).toInt(),
      maxSeenSeq: (json['max_seen_seq'] as num).toInt(),
      missingSeqs: ((json['missing_seqs'] as List?) ?? const [])
          .map((e) => (e as num).toInt())
          .toList(),
    );
  }
}

@immutable
class LanSyncStatusModel {
  const LanSyncStatusModel({
    required this.multicastLockActive,
    required this.apIsolationDetected,
    required this.localEndpointTicket,
    required this.discoveredPeers,
  });

  final bool multicastLockActive;
  final bool apIsolationDetected;
  final String localEndpointTicket;
  final List<LanPeerItemModel> discoveredPeers;

  factory LanSyncStatusModel.fromJson(Map<String, dynamic> json) {
    return LanSyncStatusModel(
      multicastLockActive: json['multicast_lock_active'] as bool? ?? true,
      apIsolationDetected: json['ap_isolation_detected'] as bool? ?? false,
      localEndpointTicket: json['local_endpoint_ticket'] as String? ?? '',
      discoveredPeers: ((json['discovered_peers'] as List?) ?? const [])
          .map((e) =>
              LanPeerItemModel.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }
}

@immutable
class OpticalQrFrameModel {
  const OpticalQrFrameModel({
    required this.packageId,
    required this.totalSourceSlices,
    required this.sliceByteLen,
    required this.totalByteLen,
    required this.sourceIndices,
    required this.payloadB64,
    required this.frameDigest,
  });

  final String packageId;
  final int totalSourceSlices;
  final int sliceByteLen;
  final int totalByteLen;
  final List<int> sourceIndices;
  final String payloadB64;
  final String frameDigest;

  bool get isParityFrame => sourceIndices.length > 1;

  Map<String, dynamic> toJson() => {
        'package_id': packageId,
        'total_source_slices': totalSourceSlices,
        'slice_byte_len': sliceByteLen,
        'total_byte_len': totalByteLen,
        'source_indices': sourceIndices,
        'payload_b64': payloadB64,
        'frame_digest': frameDigest,
      };

  factory OpticalQrFrameModel.fromJson(Map<String, dynamic> json) {
    return OpticalQrFrameModel(
      packageId: json['package_id'] as String,
      totalSourceSlices: (json['total_source_slices'] as num).toInt(),
      sliceByteLen: (json['slice_byte_len'] as num).toInt(),
      totalByteLen: (json['total_byte_len'] as num).toInt(),
      sourceIndices: (json['source_indices'] as List)
          .map((e) => (e as num).toInt())
          .toList(),
      payloadB64: json['payload_b64'] as String,
      frameDigest: json['frame_digest'] as String,
    );
  }
}

@immutable
class OpticalSessionViewModel {
  const OpticalSessionViewModel({
    required this.outgoingFrames,
    required this.recommendedFps,
    required this.slowMode,
    this.receiverActivePackageId,
    required this.receiverSolvedSlices,
    required this.receiverTotalSlices,
    required this.receiverComplete,
  });

  final List<OpticalQrFrameModel> outgoingFrames;
  final int recommendedFps;
  final bool slowMode;
  final String? receiverActivePackageId;
  final int receiverSolvedSlices;
  final int receiverTotalSlices;
  final bool receiverComplete;

  double get receiverProgress => receiverTotalSlices <= 0
      ? 0.0
      : (receiverSolvedSlices / receiverTotalSlices).clamp(0.0, 1.0);

  factory OpticalSessionViewModel.fromJson(Map<String, dynamic> json) {
    return OpticalSessionViewModel(
      outgoingFrames: ((json['outgoing_frames'] as List?) ?? const [])
          .map((e) =>
              OpticalQrFrameModel.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      recommendedFps: (json['recommended_fps'] as num?)?.toInt() ?? 5,
      slowMode: json['slow_mode'] as bool? ?? false,
      receiverActivePackageId: json['receiver_active_package_id'] as String?,
      receiverSolvedSlices:
          (json['receiver_solved_slices'] as num?)?.toInt() ?? 0,
      receiverTotalSlices:
          (json['receiver_total_slices'] as num?)?.toInt() ?? 0,
      receiverComplete: json['receiver_complete'] as bool? ?? false,
    );
  }
}

@immutable
class UiWorkspaceSnapshotModel {
  const UiWorkspaceSnapshotModel({
    required this.groupId,
    required this.groupName,
    required this.activeActorId,
    required this.activePolicyEventId,
    required this.currencies,
    required this.participants,
    required this.defaultFxRates,
    this.customCategories = const [],
    required this.expenses,
    required this.repayments,
    required this.activeObligations,
    required this.snapshots,
    required this.settlementPreviews,
    this.settlementCurrency = 'CNY',
    this.formalSettlementBlocker,
    required this.webDavStatus,
    required this.lanStatus,
    required this.opticalSession,
    this.lastSyncReport,
    required this.conflictCount,
    required this.pendingRepaymentCount,
    required this.pendingReauthCount,
    required this.totalEventCount,
  });

  final String groupId;
  final String groupName;
  final String activeActorId;
  final String activePolicyEventId;
  final Map<String, CurrencySpecModel> currencies;
  final List<ParticipantModel> participants;
  final List<FxRateSpecModel> defaultFxRates;
  final List<ExpenseCategoryModel> customCategories;
  final List<UiExpenseViewModel> expenses;

  List<ExpenseCategoryModel> get allCategories => [
        ...ExpenseCategoryModel.presetCategories,
        ...customCategories,
      ];
  final List<RepaymentItemModel> repayments;
  final List<SettlementObligationModel> activeObligations;
  final List<SnapshotProjectionModel> snapshots;
  final Map<String, UiSettlementPreviewModel> settlementPreviews;
  final String settlementCurrency;
  final String? formalSettlementBlocker;
  final WebDavStatusModel webDavStatus;
  final LanSyncStatusModel lanStatus;
  final OpticalSessionViewModel opticalSession;
  final SyncActivityReportModel? lastSyncReport;
  final int conflictCount;
  final int pendingRepaymentCount;
  final int pendingReauthCount;
  final int totalEventCount;

  ParticipantModel get activeActor => participants.firstWhere(
        (p) => p.participantId == activeActorId,
        orElse: () => participants.first,
      );

  String nameOf(String participantId) {
    for (final p in participants) {
      if (p.participantId == participantId) {
        return p.displayName;
      }
    }
    return participantId;
  }

  int decimalsOf(String currency) => currencies[currency]?.minorDecimals ?? 2;

  factory UiWorkspaceSnapshotModel.fromJson(Map<String, dynamic> json) {
    final policy = Map<String, dynamic>.from(json['policy'] as Map);
    final currMap = Map<String, dynamic>.from(policy['currencies'] as Map).map(
      (k, v) => MapEntry(
        k,
        CurrencySpecModel.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    );
    final previewsRaw =
        Map<String, dynamic>.from(json['settlement_previews'] as Map);

    return UiWorkspaceSnapshotModel(
      groupId: json['group_id'] as String,
      groupName: json['group_name'] as String,
      activeActorId: json['active_actor_id'] as String,
      activePolicyEventId: json['active_policy_event_id'] as String,
      currencies: currMap,
      participants: (json['participants'] as List)
          .map((e) =>
              ParticipantModel.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      defaultFxRates: ((json['default_fx_rates'] as List?) ?? const [])
          .map((e) =>
              FxRateSpecModel.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      customCategories: ((json['custom_categories'] as List?) ?? const [])
          .map((e) => ExpenseCategoryModel.fromJson(
              Map<String, dynamic>.from(e as Map)))
          .toList(),
      expenses: (json['expenses'] as List)
          .map((e) =>
              UiExpenseViewModel.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      repayments: (json['repayments'] as List)
          .map((e) =>
              RepaymentItemModel.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      activeObligations: ((json['active_obligations'] as List?) ?? const [])
          .map((e) => SettlementObligationModel.fromJson(
              Map<String, dynamic>.from(e as Map)))
          .toList(),
      snapshots: ((json['snapshots'] as List?) ?? const [])
          .map((e) => SnapshotProjectionModel.fromJson(
              Map<String, dynamic>.from(e as Map)))
          .toList(),
      settlementCurrency: json['settlement_currency'] as String? ?? 'CNY',
      formalSettlementBlocker: json['formal_settlement_blocker'] as String?,
      settlementPreviews: previewsRaw.map(
        (k, v) => MapEntry(
          k,
          UiSettlementPreviewModel.fromJson(
            k,
            Map<String, dynamic>.from(v as Map),
          ),
        ),
      ),
      webDavStatus: json['webdav_status'] != null
          ? WebDavStatusModel.fromJson(
              Map<String, dynamic>.from(json['webdav_status'] as Map),
            )
          : const WebDavStatusModel(
              enabled: true,
              endpointUrl: 'https://nas.local:5006/webdav/sbill_app',
              username: 'sbill_trip_member',
              opaqueGroupDir: 'opaque_trip_autumn_2026',
              simulateUnreachable: false,
              pendingUploadCount: 0,
              remoteObjectCount: 0,
            ),
      lanStatus: json['lan_status'] != null
          ? LanSyncStatusModel.fromJson(
              Map<String, dynamic>.from(json['lan_status'] as Map),
            )
          : const LanSyncStatusModel(
              multicastLockActive: true,
              apIsolationDetected: false,
              localEndpointTicket:
                  'sbill-lan://trip_autumn_2026/A@192.168.43.100:9443',
              discoveredPeers: [],
            ),
      opticalSession: json['optical_session'] != null
          ? OpticalSessionViewModel.fromJson(
              Map<String, dynamic>.from(json['optical_session'] as Map),
            )
          : const OpticalSessionViewModel(
              outgoingFrames: [],
              recommendedFps: 5,
              slowMode: false,
              receiverSolvedSlices: 0,
              receiverTotalSlices: 0,
              receiverComplete: false,
            ),
      lastSyncReport: json['last_sync_report'] != null
          ? SyncActivityReportModel.fromJson(
              Map<String, dynamic>.from(json['last_sync_report'] as Map),
            )
          : null,
      conflictCount: (json['conflict_count'] as num).toInt(),
      pendingRepaymentCount: (json['pending_repayment_count'] as num).toInt(),
      pendingReauthCount: (json['pending_reauth_count'] as num).toInt(),
      totalEventCount: (json['total_event_count'] as num).toInt(),
    );
  }
}

/// Pure integer currency formatter & deterministic Largest-Remainder previewer (no floating-point drift).
class MoneyFormatter {
  static String symbolOf(String currency) {
    switch (currency) {
      case 'CNY':
        return '¥';
      case 'USD':
        return '\$';
      case 'EUR':
        return '€';
      case 'JPY':
        return 'JP¥';
      case 'HKD':
        return 'HK\$';
      case 'GBP':
        return '£';
      case 'KWD':
        return 'KD ';
      default:
        return '$currency ';
    }
  }

  static String formatMinor(
    int amountMinor,
    String currency, {
    int decimals = 2,
    bool showPlus = false,
    bool withSymbol = true,
  }) {
    final isNeg = amountMinor < 0;
    final absVal = BigInt.from(amountMinor).abs();
    final sign = isNeg ? '-' : (showPlus && absVal > BigInt.zero ? '+' : '');
    final sym = withSymbol ? symbolOf(currency) : '';

    if (decimals <= 0) {
      return '$sign$sym${_formatThousands(absVal)}';
    }
    final scale = BigInt.from(10).pow(decimals);
    final major = absVal ~/ scale;
    final minor = (absVal % scale).toString().padLeft(decimals, '0');
    return '$sign$sym${_formatThousands(major)}.$minor';
  }

  static String _formatThousands(BigInt value) {
    final s = value.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) {
        buf.write(',');
      }
      buf.write(s[i]);
    }
    return buf.toString();
  }

  static int? parseMajorToMinor(String raw, int decimals) {
    final input = raw.trim();
    if (input.contains(',') &&
        !RegExp(r'^\d{1,3}(,\d{3})+(\.\d*)?$').hasMatch(input)) {
      return null;
    }
    final trimmed = input.replaceAll(',', '');
    if (decimals < 0 ||
        decimals > 18 ||
        trimmed.length > 80 ||
        !RegExp(r'^(\d+(\.\d*)?|\.\d+)$').hasMatch(trimmed)) {
      return null;
    }
    final parts = trimmed.split('.');
    final fraction = parts.length == 2 ? parts[1] : '';
    if (decimals == 0 &&
        fraction.isNotEmpty &&
        !RegExp(r'^0+$').hasMatch(fraction)) {
      return null;
    }
    if (decimals > 0 && fraction.length > decimals) return null;
    final major = BigInt.parse(parts[0].isEmpty ? '0' : parts[0]);
    final minor = decimals == 0
        ? BigInt.zero
        : BigInt.parse(fraction.padRight(decimals, '0'));
    final result = major * BigInt.from(10).pow(decimals) + minor;
    if (result > BigInt.parse('9223372036854775807')) return null;
    return result.toInt();
  }

  static Map<String, int> apportionByWeights(
    int totalMinor,
    Map<String, int> weights,
  ) {
    if (totalMinor <= 0 || weights.isEmpty) {
      return {for (final k in weights.keys) k: 0};
    }
    final sortedKeys = weights.keys.toList()..sort();
    var totalWeight = BigInt.zero;
    for (final k in sortedKeys) {
      final w = weights[k] ?? 0;
      if (w > 0) totalWeight += BigInt.from(w);
    }
    if (totalWeight <= BigInt.zero) {
      return {for (final k in sortedKeys) k: 0};
    }

    final result = <String, int>{};
    final remainders = <MapEntry<String, BigInt>>[];
    var sumBase = 0;

    for (final k in sortedKeys) {
      final w = weights[k] ?? 0;
      final num = BigInt.from(totalMinor) * BigInt.from(w > 0 ? w : 0);
      final quota = (num ~/ totalWeight).toInt();
      final rem = num % totalWeight;
      result[k] = quota;
      sumBase += quota;
      remainders.add(MapEntry(k, rem));
    }

    final leftover = totalMinor - sumBase;
    remainders.sort((a, b) {
      final cmp = b.value.compareTo(a.value);
      return cmp != 0 ? cmp : a.key.compareTo(b.key);
    });

    for (var i = 0; i < leftover && i < remainders.length; i++) {
      final k = remainders[i].key;
      result[k] = (result[k] ?? 0) + 1;
    }
    return result;
  }
}

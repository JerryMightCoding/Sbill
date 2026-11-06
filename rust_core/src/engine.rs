use std::collections::{BTreeMap, BTreeSet};

use crate::domain::{
    CurrencySpec, OptimalityStatus, PayerContribution, SettlementMode, SplitRule, TransferEdge,
    FxRateSpec,
};
use crate::error::{CoreError, CoreResult};

pub const ATTRIBUTION_RULE_VERSION: &str = "payer-proportion-v1";
pub const SETTLEMENT_ALGORITHM_VERSION: &str = "bitmask-zero-sum-v1";
pub const EXACT_DP_MAX_NONZERO_MEMBERS: usize = 12;

/// Deterministically apportions `total_minor` across participants proportional to `weights`
/// using the Largest Remainder Method, breaking ties by ascending `participant_id`.
pub fn apportion_by_weights(
    total_minor: i64,
    weights: &BTreeMap<String, u64>,
) -> CoreResult<BTreeMap<String, i64>> {
    if total_minor < 0 {
        return Err(CoreError::FinancialValidation(
            "total_minor cannot be negative".to_string(),
        ));
    }
    if weights.is_empty() {
        return Err(CoreError::FinancialValidation(
            "split participants cannot be empty".to_string(),
        ));
    }
    let total_weight: u128 = weights.values().map(|&w| u128::from(w)).sum();
    if total_weight == 0 {
        return Err(CoreError::FinancialValidation(
            "sum of split weights must be strictly positive".to_string(),
        ));
    }
    if total_minor == 0 {
        return Ok(weights.keys().map(|k| (k.clone(), 0)).collect());
    }

    let total_u128 = u128::try_from(total_minor).unwrap();
    let mut base_shares = BTreeMap::new();
    let mut remainders: Vec<(u128, String)> = Vec::with_capacity(weights.len());
    let mut sum_base: i64 = 0;

    for (participant_id, &w) in weights {
        let num = total_u128
            .checked_mul(u128::from(w))
            .ok_or_else(|| CoreError::FinancialValidation("weight multiplication overflow".to_string()))?;
        let quota = i64::try_from(num / total_weight)
            .map_err(|_| CoreError::FinancialValidation("share quota overflow".to_string()))?;
        let rem = num % total_weight;
        base_shares.insert(participant_id.clone(), quota);
        sum_base += quota;
        remainders.push((rem, participant_id.clone()));
    }

    let leftover = usize::try_from(total_minor - sum_base)
        .map_err(|_| CoreError::FinancialValidation("invalid remainder count".to_string()))?;

    // Sort by descending remainder, then ascending participant_id for deterministic tie-breaking.
    remainders.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));

    for (_, participant_id) in remainders.into_iter().take(leftover) {
        if let Some(val) = base_shares.get_mut(&participant_id) {
            *val += 1;
        }
    }

    let final_sum: i64 = base_shares.values().sum();
    debug_assert_eq!(final_sum, total_minor);
    Ok(base_shares)
}

/// Computes resolved shares for a bill according to its `SplitRule`.
pub fn compute_resolved_shares(
    total_minor: i64,
    split_rule: &SplitRule,
    voided: bool,
) -> CoreResult<BTreeMap<String, i64>> {
    if voided {
        return match split_rule {
            SplitRule::Equal { participants } => {
                Ok(participants.iter().map(|p| (p.clone(), 0)).collect())
            }
            SplitRule::ExactAmounts { shares } => {
                Ok(shares.keys().map(|p| (p.clone(), 0)).collect())
            }
            SplitRule::Ratios { ratios } => Ok(ratios.keys().map(|p| (p.clone(), 0)).collect()),
            SplitRule::Weights { weights } => Ok(weights.keys().map(|p| (p.clone(), 0)).collect()),
        };
    }
    if total_minor <= 0 {
        return Err(CoreError::FinancialValidation(
            "active expense total_minor must be strictly positive".to_string(),
        ));
    }

    match split_rule {
        SplitRule::Equal { participants } => {
            if participants.is_empty() {
                return Err(CoreError::FinancialValidation(
                    "equal split requires at least one participant".to_string(),
                ));
            }
            let mut weights = BTreeMap::new();
            for p in participants {
                if weights.insert(p.clone(), 1_u64).is_some() {
                    return Err(CoreError::FinancialValidation(format!(
                        "duplicate participant '{p}' in equal split"
                    )));
                }
            }
            apportion_by_weights(total_minor, &weights)
        }
        SplitRule::ExactAmounts { shares } => {
            if shares.is_empty() {
                return Err(CoreError::FinancialValidation(
                    "exact amount split cannot be empty".to_string(),
                ));
            }
            let mut sum: i64 = 0;
            for (p, &amount) in shares {
                if amount < 0 {
                    return Err(CoreError::FinancialValidation(format!(
                        "negative share amount for participant '{p}'"
                    )));
                }
                sum = sum.checked_add(amount).ok_or_else(|| {
                    CoreError::FinancialValidation("share sum overflow".to_string())
                })?;
            }
            if sum != total_minor {
                return Err(CoreError::FinancialValidation(format!(
                    "sum of exact shares ({sum}) does not equal bill total ({total_minor})"
                )));
            }
            Ok(shares.clone())
        }
        SplitRule::Ratios { ratios } => apportion_by_weights(total_minor, ratios),
        SplitRule::Weights { weights } => apportion_by_weights(total_minor, weights),
    }
}

/// Computes the deterministic pairwise debt attribution matrix (`debtor -> creditor -> amount_minor`)
/// with exact 2D marginal conservation (every debtor's row sums to `share`, every creditor's column
/// sums to `paid`, and opposite cells between the same pair are netted).
pub fn compute_attribution_matrix(
    total_minor: i64,
    payers: &[PayerContribution],
    resolved_shares: &BTreeMap<String, i64>,
    voided: bool,
) -> CoreResult<BTreeMap<String, BTreeMap<String, i64>>> {
    if voided {
        return Ok(BTreeMap::new());
    }
    if payers.is_empty() {
        return Err(CoreError::FinancialValidation(
            "expense must have at least one payer".to_string(),
        ));
    }

    let mut paid_by_member: BTreeMap<String, i64> = BTreeMap::new();
    let mut sum_paid: i64 = 0;
    for p in payers {
        if p.amount_minor <= 0 {
            return Err(CoreError::FinancialValidation(format!(
                "payer '{}' amount_minor must be positive",
                p.participant_id
            )));
        }
        sum_paid = sum_paid.checked_add(p.amount_minor).ok_or_else(|| {
            CoreError::FinancialValidation("payer total overflow".to_string())
        })?;
        *paid_by_member.entry(p.participant_id.clone()).or_insert(0) += p.amount_minor;
    }

    if sum_paid != total_minor {
        return Err(CoreError::FinancialValidation(format!(
            "sum of payer contributions ({sum_paid}) does not equal bill total ({total_minor})"
        )));
    }

    let sum_shares: i64 = resolved_shares.values().sum();
    if sum_shares != total_minor {
        return Err(CoreError::FinancialValidation(format!(
            "sum of resolved shares ({sum_shares}) does not equal bill total ({total_minor})"
        )));
    }

    let total_i128 = i128::from(total_minor);
    let debtors: Vec<String> = resolved_shares.keys().cloned().collect();
    let creditors: Vec<String> = paid_by_member.keys().cloned().collect();

    // Base floor allocation M[debtor][creditor] = floor(share[debtor] * paid[creditor] / total)
    let mut gross: BTreeMap<(String, String), i64> = BTreeMap::new();
    let mut row_deficit: BTreeMap<String, i64> = resolved_shares.clone();
    let mut col_deficit: BTreeMap<String, i64> = paid_by_member.clone();
    let mut candidates: Vec<(i128, String, String)> =
        Vec::with_capacity(debtors.len() * creditors.len());

    for d in &debtors {
        let share = i128::from(resolved_shares[d]);
        for c in &creditors {
            let paid = i128::from(paid_by_member[c]);
            let num = share * paid;
            let floor_val = i64::try_from(num / total_i128).unwrap();
            let rem = num % total_i128;
            gross.insert((d.clone(), c.clone()), floor_val);
            *row_deficit.get_mut(d).unwrap() -= floor_val;
            *col_deficit.get_mut(c).unwrap() -= floor_val;
            candidates.push((rem, d.clone(), c.clone()));
        }
    }

    // Sort by descending remainder, then debtor_id ascending, then creditor_id ascending.
    candidates.sort_by(|a, b| {
        b.0.cmp(&a.0)
            .then_with(|| a.1.cmp(&b.1))
            .then_with(|| a.2.cmp(&b.2))
    });

    // Pass 1: allocate leftover units to high-remainder cells where both row and col need units.
    for (_, d, c) in &candidates {
        let r_def = row_deficit[d];
        let c_def = col_deficit[c];
        if r_def > 0 && c_def > 0 {
            *gross.get_mut(&(d.clone(), c.clone())).unwrap() += 1;
            *row_deficit.get_mut(d).unwrap() -= 1;
            *col_deficit.get_mut(c).unwrap() -= 1;
        }
    }

    // Pass 2: if any row/col still has deficit, pair remaining deficits deterministically.
    for d in &debtors {
        while row_deficit[d] > 0 {
            let c = creditors
                .iter()
                .find(|&cred| col_deficit[cred] > 0)
                .expect("sum of row deficits equals sum of col deficits");
            *gross.get_mut(&(d.clone(), c.clone())).unwrap() += 1;
            *row_deficit.get_mut(d).unwrap() -= 1;
            *col_deficit.get_mut(c).unwrap() -= 1;
        }
    }

    // Net opposite directions between each unordered pair and drop self-edges.
    let all_members: BTreeSet<String> = debtors
        .into_iter()
        .chain(creditors.into_iter())
        .collect();
    let member_vec: Vec<String> = all_members.into_iter().collect();
    let mut matrix: BTreeMap<String, BTreeMap<String, i64>> = BTreeMap::new();

    for i in 0..member_vec.len() {
        for j in (i + 1)..member_vec.len() {
            let u = &member_vec[i];
            let v = &member_vec[j];
            let u_owes_v = gross.get(&(u.clone(), v.clone())).copied().unwrap_or(0);
            let v_owes_u = gross.get(&(v.clone(), u.clone())).copied().unwrap_or(0);
            let net = u_owes_v - v_owes_u;
            if net > 0 {
                matrix
                    .entry(u.clone())
                    .or_default()
                    .insert(v.clone(), net);
            } else if net < 0 {
                matrix
                    .entry(v.clone())
                    .or_default()
                    .insert(u.clone(), -net);
            }
        }
    }

    Ok(matrix)
}

#[derive(Debug, Clone)]
pub struct SettlementComputationResult {
    pub mode: SettlementMode,
    pub settlement_currency: Option<String>,
    pub net_balances_by_currency: BTreeMap<String, BTreeMap<String, i64>>,
    pub transfers: Vec<TransferEdge>,
    pub optimality: OptimalityStatus,
}

/// Helper to add a directed debt `debtor -> creditor` into an unordered-pair canonical map
/// `(min_id, max_id) -> signed_amount` (positive means `min_id` owes `max_id`).
pub fn add_canonical_pair_debt(
    pair_map: &mut BTreeMap<(String, String), i64>,
    debtor: &str,
    creditor: &str,
    amount_minor: i64,
) {
    if debtor == creditor || amount_minor == 0 {
        return;
    }
    let (first, second, signed) = if debtor < creditor {
        (debtor.to_string(), creditor.to_string(), amount_minor)
    } else {
        (creditor.to_string(), debtor.to_string(), -amount_minor)
    };
    let entry = pair_map.entry((first, second)).or_insert(0);
    *entry += signed;
    if *entry == 0 {
        pair_map.remove(&(
            if debtor < creditor {
                debtor.to_string()
            } else {
                creditor.to_string()
            },
            if debtor < creditor {
                creditor.to_string()
            } else {
                debtor.to_string()
            },
        ));
    }
}

pub fn pair_map_to_transfer_edges(
    currency: &str,
    pair_map: &BTreeMap<(String, String), i64>,
) -> Vec<TransferEdge> {
    let mut edges = Vec::new();
    for ((first, second), &signed) in pair_map {
        if signed > 0 {
            edges.push(TransferEdge {
                debtor_id: first.clone(),
                creditor_id: second.clone(),
                currency: currency.to_string(),
                amount_minor: signed,
            });
        } else if signed < 0 {
            edges.push(TransferEdge {
                debtor_id: second.clone(),
                creditor_id: first.clone(),
                currency: currency.to_string(),
                amount_minor: -signed,
            });
        }
    }
    edges.sort();
    edges
}

pub fn balances_from_pair_map(
    all_participants: &BTreeSet<String>,
    pair_map: &BTreeMap<(String, String), i64>,
) -> BTreeMap<String, i64> {
    let mut balances: BTreeMap<String, i64> =
        all_participants.iter().map(|p| (p.clone(), 0)).collect();
    for ((first, second), &signed) in pair_map {
        *balances.entry(first.clone()).or_insert(0) -= signed;
        *balances.entry(second.clone()).or_insert(0) += signed;
    }
    balances
}

/// Solves for a deterministic transfer plan for a single currency given `balances` (`sum == 0`).
/// Uses exact zero-sum subset partitioning (Bitmask DP) when non-zero participants <= 12,
/// and deterministic greedy matching otherwise.
pub fn solve_min_transfers_single_currency(
    currency: &str,
    balances: &BTreeMap<String, i64>,
) -> CoreResult<(Vec<TransferEdge>, OptimalityStatus)> {
    let total_sum: i64 = balances.values().sum();
    if total_sum != 0 {
        return Err(CoreError::Settlement(format!(
            "currency '{currency}' net balances sum to {total_sum}, expected 0"
        )));
    }

    let nonzero: Vec<(String, i64)> = balances
        .iter()
        .filter(|(_, &b)| b != 0)
        .map(|(k, &b)| (k.clone(), b))
        .collect();

    if nonzero.is_empty() {
        return Ok((Vec::new(), OptimalityStatus::ProvenOptimal));
    }

    if nonzero.len() > EXACT_DP_MAX_NONZERO_MEMBERS {
        let edges = greedy_settle_group(currency, &nonzero);
        return Ok((edges, OptimalityStatus::HeuristicFeasible));
    }

    let n = nonzero.len();
    let full_mask = (1usize << n) - 1;
    let mut subset_sums = vec![0i64; 1usize << n];
    for mask in 1..=full_mask {
        let lowest_bit = mask & mask.wrapping_neg();
        let bit_idx = lowest_bit.trailing_zeros() as usize;
        subset_sums[mask] = subset_sums[mask ^ lowest_bit] + nonzero[bit_idx].1;
    }

    // `dp_count[mask]` = max number of disjoint zero-sum subsets in `mask`.
    // `dp_choice[mask]` = chosen atomic zero-sum submask containing `anchor` that yields canonical best plan.
    let mut dp_count = vec![0usize; 1usize << n];
    let mut dp_edges: Vec<Vec<TransferEdge>> = vec![Vec::new(); 1usize << n];

    for mask in 1..=full_mask {
        if subset_sums[mask] != 0 {
            continue;
        }
        let anchor = mask & mask.wrapping_neg();
        let mut best_groups = 1usize;
        let mut best_plan = settle_atomic_zero_sum_subset(currency, &nonzero, mask);

        let mut sub = (mask - 1) & mask;
        while sub > 0 {
            if (sub & anchor) != 0 && subset_sums[sub] == 0 {
                let rem = mask ^ sub;
                if subset_sums[rem] == 0 && dp_count[rem] > 0 {
                    let candidate_groups = 1 + dp_count[rem];
                    if candidate_groups > best_groups {
                        let mut candidate_plan =
                            settle_atomic_zero_sum_subset(currency, &nonzero, sub);
                        candidate_plan.extend(dp_edges[rem].iter().cloned());
                        candidate_plan.sort();
                        best_groups = candidate_groups;
                        best_plan = candidate_plan;
                    } else if candidate_groups == best_groups {
                        let mut candidate_plan =
                            settle_atomic_zero_sum_subset(currency, &nonzero, sub);
                        candidate_plan.extend(dp_edges[rem].iter().cloned());
                        candidate_plan.sort();
                        if candidate_plan < best_plan {
                            best_plan = candidate_plan;
                        }
                    }
                }
            }
            sub = (sub - 1) & mask;
        }

        dp_count[mask] = best_groups;
        dp_edges[mask] = best_plan;
    }

    let final_edges = dp_edges[full_mask].clone();
    debug_assert_eq!(final_edges.len(), n - dp_count[full_mask]);
    Ok((final_edges, OptimalityStatus::ProvenOptimal))
}

fn settle_atomic_zero_sum_subset(
    currency: &str,
    nonzero: &[(String, i64)],
    mask: usize,
) -> Vec<TransferEdge> {
    let mut subset_items = Vec::new();
    for (idx, item) in nonzero.iter().enumerate() {
        if (mask & (1usize << idx)) != 0 {
            subset_items.push(item.clone());
        }
    }
    greedy_settle_group(currency, &subset_items)
}

/// Deterministic greedy settlement within a single zero-sum group.
/// Picks largest debtor (ties broken by ascending ID) and largest creditor (ties broken by ascending ID).
fn greedy_settle_group(currency: &str, items: &[(String, i64)]) -> Vec<TransferEdge> {
    let mut debtors: Vec<(String, i64)> = items
        .iter()
        .filter(|(_, b)| *b < 0)
        .map(|(id, b)| (id.clone(), -*b))
        .collect();
    let mut creditors: Vec<(String, i64)> = items
        .iter()
        .filter(|(_, b)| *b > 0)
        .map(|(id, b)| (id.clone(), *b))
        .collect();

    let mut edges = Vec::new();
    while !debtors.is_empty() && !creditors.is_empty() {
        debtors.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        creditors.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));

        let amount = debtors[0].1.min(creditors[0].1);
        edges.push(TransferEdge {
            debtor_id: debtors[0].0.clone(),
            creditor_id: creditors[0].0.clone(),
            currency: currency.to_string(),
            amount_minor: amount,
        });

        debtors[0].1 -= amount;
        creditors[0].1 -= amount;
        if debtors[0].1 == 0 {
            debtors.remove(0);
        }
        if creditors[0].1 == 0 {
            creditors.remove(0);
        }
    }
    edges.sort();
    edges
}

/// Computes settlement across the 4 supported modes given per-currency canonical pair debts.
pub fn compute_settlement_from_pair_debts(
    all_participants: &BTreeSet<String>,
    currencies: &BTreeMap<String, CurrencySpec>,
    per_currency_pair_debts: &BTreeMap<String, BTreeMap<(String, String), i64>>,
    mode: SettlementMode,
    settlement_currency: Option<&str>,
    fx_rates: &[FxRateSpec],
) -> CoreResult<SettlementComputationResult> {
    match mode {
        SettlementMode::ByCurrencyPairwise => {
            let mut net_balances_by_currency = BTreeMap::new();
            let mut transfers = Vec::new();
            for (curr, pair_map) in per_currency_currency_sorted(per_currency_pair_debts) {
                let balances = balances_from_pair_map(all_participants, pair_map);
                if balances.values().any(|&v| v != 0) {
                    net_balances_by_currency.insert(curr.clone(), balances);
                }
                transfers.extend(pair_map_to_transfer_edges(curr, pair_map));
            }
            Ok(SettlementComputationResult {
                mode,
                settlement_currency: None,
                net_balances_by_currency,
                transfers,
                optimality: OptimalityStatus::ProvenOptimal,
            })
        }
        SettlementMode::ByCurrencyMinTransfers => {
            let mut net_balances_by_currency = BTreeMap::new();
            let mut transfers = Vec::new();
            let mut overall_opt = OptimalityStatus::ProvenOptimal;
            for (curr, pair_map) in per_currency_currency_sorted(per_currency_pair_debts) {
                let balances = balances_from_pair_map(all_participants, pair_map);
                if balances.values().any(|&v| v != 0) {
                    let (curr_edges, opt) = solve_min_transfers_single_currency(curr, &balances)?;
                    if opt == OptimalityStatus::HeuristicFeasible {
                        overall_opt = OptimalityStatus::HeuristicFeasible;
                    }
                    net_balances_by_currency.insert(curr.clone(), balances);
                    transfers.extend(curr_edges);
                }
            }
            Ok(SettlementComputationResult {
                mode,
                settlement_currency: None,
                net_balances_by_currency,
                transfers,
                optimality: overall_opt,
            })
        }
        SettlementMode::MergedCurrencyPairwise | SettlementMode::MergedCurrencyMinTransfers => {
            let target_curr = settlement_currency.ok_or_else(|| {
                CoreError::Settlement(
                    "merged currency settlement requires a target settlement_currency".to_string(),
                )
            })?;
            let target_spec = currencies.get(target_curr).ok_or_else(|| {
                CoreError::Settlement(format!("unknown settlement currency '{target_curr}'"))
            })?;

            let mut merged_pair_map: BTreeMap<(String, String), i64> = BTreeMap::new();
            for (curr, pair_map) in per_currency_currency_sorted(per_currency_pair_debts) {
                let src_spec = currencies.get(curr).ok_or_else(|| {
                    CoreError::Settlement(format!("unknown source currency '{curr}'"))
                })?;
                for ((first, second), &signed_amount) in pair_map {
                    if signed_amount == 0 {
                        continue;
                    }
                    let converted = if curr == target_curr {
                        signed_amount
                    } else {
                        let rate = find_fx_rate(fx_rates, curr, target_curr)?;
                        rate.convert_minor(
                            signed_amount,
                            src_spec.minor_decimals,
                            target_spec.minor_decimals,
                        )?
                    };
                    if converted != 0 {
                        let entry = merged_pair_map
                            .entry((first.clone(), second.clone()))
                            .or_insert(0);
                        *entry += converted;
                        if *entry == 0 {
                            merged_pair_map.remove(&(first.clone(), second.clone()));
                        }
                    }
                }
            }

            let merged_balances = balances_from_pair_map(all_participants, &merged_pair_map);
            let mut net_balances_by_currency = BTreeMap::new();
            net_balances_by_currency.insert(target_curr.to_string(), merged_balances.clone());

            if mode == SettlementMode::MergedCurrencyPairwise {
                let transfers = pair_map_to_transfer_edges(target_curr, &merged_pair_map);
                Ok(SettlementComputationResult {
                    mode,
                    settlement_currency: Some(target_curr.to_string()),
                    net_balances_by_currency,
                    transfers,
                    optimality: OptimalityStatus::ProvenOptimal,
                })
            } else {
                let (transfers, optimality) =
                    solve_min_transfers_single_currency(target_curr, &merged_balances)?;
                Ok(SettlementComputationResult {
                    mode,
                    settlement_currency: Some(target_curr.to_string()),
                    net_balances_by_currency,
                    transfers,
                    optimality,
                })
            }
        }
    }
}

fn per_currency_currency_sorted(
    map: &BTreeMap<String, BTreeMap<(String, String), i64>>,
) -> impl Iterator<Item = (&String, &BTreeMap<(String, String), i64>)> {
    map.iter()
}

fn find_fx_rate(
    fx_rates: &[FxRateSpec],
    base_currency: &str,
    quote_currency: &str,
) -> CoreResult<FxRateSpec> {
    for r in fx_rates {
        if r.base_currency == base_currency && r.quote_currency == quote_currency {
            return Ok(r.clone());
        }
        if r.base_currency == quote_currency && r.quote_currency == base_currency {
            return FxRateSpec::new(base_currency, quote_currency, r.denominator, r.numerator);
        }
    }
    Err(CoreError::Settlement(format!(
        "missing frozen FX rate between '{base_currency}' and '{quote_currency}'"
    )))
}

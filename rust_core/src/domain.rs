use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

use crate::crypto::{
    blake3_hash_b64, canonical_json_bytes, verify_ed25519_signature, DeviceKeypair,
    EVENT_MAX_BYTES,
};
use crate::error::{CoreError, CoreResult};

pub const CURRENT_SCHEMA_VERSION: u32 = 3;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum Role {
    Owner,
    FinanceEditor,
    Member,
    Viewer,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum Capability {
    BillCreate,
    BillEditOwn,
    BillEditAny,
    BillVoid,
    ConflictResolve,
    SettlementPublish,
    MemberManage,
}

impl Role {
    pub fn default_capabilities(self) -> BTreeSet<Capability> {
        use Capability::*;
        match self {
            Role::Owner => [
                BillCreate,
                BillEditOwn,
                BillEditAny,
                BillVoid,
                ConflictResolve,
                SettlementPublish,
                MemberManage,
            ]
            .into_iter()
            .collect(),
            Role::FinanceEditor => [
                BillCreate,
                BillEditOwn,
                BillEditAny,
                BillVoid,
                ConflictResolve,
                SettlementPublish,
            ]
            .into_iter()
            .collect(),
            Role::Member => [BillCreate, BillEditOwn].into_iter().collect(),
            Role::Viewer => BTreeSet::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CurrencySpec {
    pub code: String,
    pub minor_decimals: u8,
}

impl CurrencySpec {
    pub fn default_catalog() -> BTreeMap<String, CurrencySpec> {
        [
            ("CNY", 2),
            ("USD", 2),
            ("EUR", 2),
            ("JPY", 0),
            ("HKD", 2),
            ("GBP", 2),
            ("THB", 2),
            ("KRW", 0),
            ("KWD", 3),
        ]
        .into_iter()
        .map(|(code, minor_decimals)| {
            (
                code.to_string(),
                CurrencySpec {
                    code: code.to_string(),
                    minor_decimals,
                },
            )
        })
        .collect()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ParticipantProfile {
    pub participant_id: String,
    pub display_name: String,
    /// Present if this participant has installed the app and bound a cryptographic identity.
    /// `None` for accounting-only participants (FR-GRP-02, AC-G02).
    pub bound_public_key: Option<String>,
    pub role: Role,
    pub active: bool,
    pub extra_capabilities: BTreeSet<Capability>,
}

impl ParticipantProfile {
    pub fn has_capability(&self, capability: Capability) -> bool {
        if !self.active {
            return false;
        }
        self.role.default_capabilities().contains(&capability)
            || self.extra_capabilities.contains(&capability)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyPayload {
    pub policy_seq: u64,
    pub previous_policy_event_id: Option<String>,
    pub group_name: String,
    pub owner_member_id: String,
    pub settlement_coordinator_id: String,
    pub currencies: BTreeMap<String, CurrencySpec>,
    pub participants: BTreeMap<String, ParticipantProfile>,
    /// Causal checkpoint `device_id -> max_accepted_sequence` when privileges are revoked.
    /// Unconfirmed operations created under an older policy whose device sequence exceeds
    /// this checkpoint are marked `PendingReauth` instead of relying on wall-clock timestamps.
    pub accepted_device_checkpoints: BTreeMap<String, u64>,
}

/// Exact rational exchange rate:
/// `1 major unit of base_currency = (numerator / denominator) major units of quote_currency`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FxRateSpec {
    pub base_currency: String,
    pub quote_currency: String,
    pub numerator: i64,
    pub denominator: i64,
}

impl FxRateSpec {
    pub fn new(base_currency: &str, quote_currency: &str, numerator: i64, denominator: i64) -> CoreResult<Self> {
        if numerator <= 0 || denominator <= 0 {
            return Err(CoreError::FinancialValidation(
                "FX rate numerator and denominator must be strictly positive".to_string(),
            ));
        }
        Ok(Self {
            base_currency: base_currency.to_string(),
            quote_currency: quote_currency.to_string(),
            numerator,
            denominator,
        })
    }

    /// Converts `amount_minor` in `base_currency` into `quote_currency` minor units,
    /// rounding to nearest integer with ties rounded half-up away from zero.
    pub fn convert_minor(
        &self,
        amount_minor: i64,
        base_decimals: u8,
        quote_decimals: u8,
    ) -> CoreResult<i64> {
        if self.numerator <= 0 || self.denominator <= 0 ||
            base_decimals > 18 || quote_decimals > 18 {
            return Err(CoreError::FinancialValidation(
                "invalid FX rate or currency precision".to_string(),
            ));
        }
        if self.base_currency == self.quote_currency && self.numerator == self.denominator {
            return Ok(amount_minor);
        }
        let scale_num = 10_i128.pow(u32::from(quote_decimals));
        let scale_den = 10_i128.pow(u32::from(base_decimals));
        let eff_num = i128::from(self.numerator)
            .checked_mul(scale_num)
            .ok_or_else(|| CoreError::FinancialValidation("FX numerator overflow".to_string()))?;
        let eff_den = i128::from(self.denominator)
            .checked_mul(scale_den)
            .ok_or_else(|| CoreError::FinancialValidation("FX denominator overflow".to_string()))?;

        let sign = if amount_minor < 0 { -1_i128 } else { 1_i128 };
        let abs_val = i128::from(amount_minor).abs();
        let prod = abs_val
            .checked_mul(eff_num)
            .ok_or_else(|| CoreError::FinancialValidation("FX conversion overflow".to_string()))?;
        let rounded_abs = prod.checked_add(eff_den / 2)
            .ok_or_else(|| CoreError::FinancialValidation("FX rounding overflow".to_string()))?
            / eff_den;
        let signed = sign * rounded_abs;
        i64::try_from(signed)
            .map_err(|_| CoreError::FinancialValidation("FX converted amount exceeds i64".to_string()))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PayerContribution {
    pub participant_id: String,
    /// Amount credited in the bill's accounting currency (in minor units).
    pub amount_minor: i64,
    /// Optional original payment currency if paid in a foreign currency (FR-EXP-02, AC-E07).
    pub original_currency: Option<String>,
    pub original_amount_minor: Option<i64>,
    pub frozen_fx_rate: Option<FxRateSpec>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum SplitRule {
    Equal {
        participants: Vec<String>,
    },
    ExactAmounts {
        shares: BTreeMap<String, i64>,
    },
    Ratios {
        ratios: BTreeMap<String, u64>,
    },
    Weights {
        weights: BTreeMap<String, u64>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttachmentRef {
    pub attachment_id: String,
    pub mime_type: String,
    pub byte_len: u64,
    pub ciphertext_blake3: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExpenseCategory {
    pub id: String,
    pub icon: String,
    pub name: String,
    pub is_custom: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExpenseDetails {
    pub occurred_at_ms: Option<i64>,
    /// Frozen label survives category removal; it does not recreate the catalog entry.
    pub category: Option<ExpenseCategory>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExpenseRevisionPayload {
    pub expense_id: String,
    /// Empty for creation; 1 parent for normal edit; >=2 parents when resolving concurrent branches.
    pub parent_revision_event_ids: Vec<String>,
    pub currency: String,
    pub total_minor: i64,
    pub payers: Vec<PayerContribution>,
    pub split_rule: SplitRule,
    /// Deterministically computed shares per participant in `currency` minor units.
    pub resolved_shares: BTreeMap<String, i64>,
    /// Deterministic pairwise debt attribution: `debtor -> creditor -> amount_minor`.
    pub attribution_matrix: BTreeMap<String, BTreeMap<String, i64>>,
    pub attribution_rule_version: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details: Option<ExpenseDetails>,
    pub title: String,
    pub note: String,
    pub revision_reason: String,
    pub attachment_refs: Vec<AttachmentRef>,
    pub voided: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RepaymentDeclarePayload {
    pub payment_id: String,
    pub payer_id: String,
    pub payee_id: String,
    pub currency: String,
    pub amount_minor: i64,
    /// Optional settlement obligation that this payment fulfills.
    pub target_obligation_id: Option<String>,
    pub external_reference: Option<String>,
    pub note: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RepaymentConfirmPayload {
    pub payment_id: String,
    pub declare_event_id: String,
    /// How any overpayment should be handled (`RefundNeeded` or `AdvanceCredit`).
    pub overpayment_policy: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RepaymentDisputePayload {
    pub payment_id: String,
    pub declare_event_id: String,
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RepaymentMapObligationPayload {
    pub payment_id: String,
    pub target_obligation_id: String,
    pub note: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum SettlementMode {
    ByCurrencyPairwise,
    ByCurrencyMinTransfers,
    MergedCurrencyPairwise,
    MergedCurrencyMinTransfers,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum OptimalityStatus {
    ProvenOptimal,
    HeuristicFeasible,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct TransferEdge {
    pub debtor_id: String,
    pub creditor_id: String,
    pub currency: String,
    pub amount_minor: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SettlementObligation {
    pub obligation_id: String,
    pub snapshot_id: String,
    pub debtor_id: String,
    pub creditor_id: String,
    pub currency: String,
    pub total_amount_minor: i64,
    pub paid_amount_minor: i64,
}

impl SettlementObligation {
    pub fn remaining_minor(&self) -> i64 {
        (self.total_amount_minor - self.paid_amount_minor).max(0)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SettlementSnapshotPayload {
    pub snapshot_id: String,
    pub previous_commit_event_id: Option<String>,
    pub mode: SettlementMode,
    pub settlement_currency: Option<String>,
    pub fx_rates: Vec<FxRateSpec>,
    /// Expense ID -> active revision event ID covered by this snapshot.
    pub covered_expense_revisions: BTreeMap<String, String>,
    /// Confirmed repayment IDs already accounted for in this snapshot.
    pub covered_repayment_ids: Vec<String>,
    /// Prior open obligation IDs superseded/novated by this snapshot.
    pub novated_obligation_ids: Vec<String>,
    /// Per-currency net balances (`currency -> participant_id -> balance_minor`).
    pub net_balances_by_currency: BTreeMap<String, BTreeMap<String, i64>>,
    pub transfers: Vec<TransferEdge>,
    pub optimality: OptimalityStatus,
    pub algorithm_version: String,
    pub required_approvers: BTreeSet<String>,
    pub snapshot_digest: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SettlementApprovePayload {
    pub snapshot_id: String,
    pub snapshot_digest: String,
    pub approver_participant_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SettlementCommitPayload {
    pub snapshot_id: String,
    pub snapshot_digest: String,
    pub previous_commit_event_id: Option<String>,
    pub approval_event_ids: Vec<String>,
    pub obligations: Vec<SettlementObligation>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CustomCategoryUpsertPayload {
    pub category_id: String,
    pub icon: String,
    pub name: String,
    pub deleted: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub observed_add_event_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload")]
pub enum EventBody {
    PolicyUpdate(PolicyPayload),
    ExpenseUpsert(ExpenseRevisionPayload),
    CategoryUpsert(CustomCategoryUpsertPayload),
    RepaymentDeclare(RepaymentDeclarePayload),
    RepaymentConfirm(RepaymentConfirmPayload),
    RepaymentDispute(RepaymentDisputePayload),
    RepaymentMapObligation(RepaymentMapObligationPayload),
    SettlementPropose(SettlementSnapshotPayload),
    SettlementApprove(SettlementApprovePayload),
    SettlementCommit(SettlementCommitPayload),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UnsignedEvent {
    pub schema_version: u32,
    pub group_id: String,
    pub author_member_id: String,
    pub author_public_key: String,
    pub device_id: String,
    pub sequence: u64,
    pub previous_event_id: Option<String>,
    pub policy_version_id: String,
    pub body: EventBody,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignedEvent {
    pub event_id: String,
    pub unsigned: UnsignedEvent,
    pub signature: String,
}

impl SignedEvent {
    pub fn sign_new(unsigned: UnsignedEvent, keypair: &DeviceKeypair) -> CoreResult<Self> {
        if unsigned.author_public_key != keypair.public_key_b64() {
            return Err(CoreError::Crypto(
                "UnsignedEvent author_public_key does not match signing keypair".to_string(),
            ));
        }
        let canonical = canonical_json_bytes(&unsigned)?;
        if canonical.len() > EVENT_MAX_BYTES {
            return Err(CoreError::LimitExceeded(format!(
                "single event size {} exceeds {} bytes",
                canonical.len(),
                EVENT_MAX_BYTES
            )));
        }
        let event_id = blake3_hash_b64(&canonical);
        let signature = keypair.sign(&canonical);
        Ok(Self {
            event_id,
            unsigned,
            signature,
        })
    }

    pub fn verify_cryptographic_integrity(&self) -> CoreResult<()> {
        if self.unsigned.sequence == 0 || self.unsigned.sequence > i64::MAX as u64 {
            return Err(CoreError::LimitExceeded("设备序号超出持久化范围".into()));
        }
        if self.unsigned.schema_version == 0 || self.unsigned.schema_version > CURRENT_SCHEMA_VERSION {
            return Err(CoreError::SyncPackage(format!("事件协议版本 {} 不支持，请先升级应用", self.unsigned.schema_version)));
        }
        if self.unsigned.schema_version < 3 && matches!(&self.unsigned.body,
            EventBody::ExpenseUpsert(exp) if exp.details.is_some()) {
            return Err(CoreError::SyncPackage("账目时间和分类资料需要事件协议 V3".into()));
        }
        let canonical = canonical_json_bytes(&self.unsigned)?;
        if canonical.len() > EVENT_MAX_BYTES {
            return Err(CoreError::LimitExceeded(format!(
                "single event size {} exceeds {} bytes",
                canonical.len(),
                EVENT_MAX_BYTES
            )));
        }
        let expected_id = blake3_hash_b64(&canonical);
        if expected_id != self.event_id {
            return Err(CoreError::EventIdMismatch {
                expected: expected_id,
                actual: self.event_id.clone(),
            });
        }
        verify_ed25519_signature(
            &self.unsigned.author_public_key,
            &canonical,
            &self.signature,
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum EventApplyStatus {
    Applied,
    Duplicate,
    PendingDependency,
    PendingReauth,
    ConflictBranch,
}

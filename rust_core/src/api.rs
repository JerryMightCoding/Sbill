use std::collections::{BTreeMap, BTreeSet};

use crate::crypto::{blake3_hash_b64, canonical_json_bytes, DeviceKeypair, GroupCipher};
use crate::domain::*;
use crate::engine::*;
use crate::error::{CoreError, CoreResult};
use crate::storage::*;
use crate::sync::*;

/// High-level local node facade representing one user's phone holding a local SQLite replica,
/// a device signing keypair, and the group's symmetric cipher.
pub struct LedgerNode {
    pub group_id: String,
    pub member_id: String,
    pub device_id: String,
    pub keypair: DeviceKeypair,
    pub cipher: GroupCipher,
    pub repo: LedgerRepository,
}

impl LedgerNode {
    pub fn new_in_memory(
        group_id: &str,
        member_id: &str,
        device_id: &str,
        keypair: DeviceKeypair,
        cipher: GroupCipher,
    ) -> CoreResult<Self> {
        Ok(Self {
            group_id: group_id.to_string(),
            member_id: member_id.to_string(),
            device_id: device_id.to_string(),
            keypair,
            cipher,
            repo: LedgerRepository::open_in_memory()?,
        })
    }

    pub fn create_group_genesis(
        &mut self,
        group_name: &str,
        participants: BTreeMap<String, ParticipantProfile>,
    ) -> CoreResult<SignedEvent> {
        let policy = PolicyPayload {
            policy_seq: 1,
            previous_policy_event_id: None,
            group_name: group_name.to_string(),
            owner_member_id: self.member_id.clone(),
            settlement_coordinator_id: self.member_id.clone(),
            currencies: CurrencySpec::default_catalog(),
            participants,
            accepted_device_checkpoints: BTreeMap::new(),
        };
        let unsigned = UnsignedEvent {
            schema_version: CURRENT_SCHEMA_VERSION,
            group_id: self.group_id.clone(),
            author_member_id: self.member_id.clone(),
            author_public_key: self.keypair.public_key_b64(),
            device_id: self.device_id.clone(),
            sequence: 1,
            previous_event_id: None,
            policy_version_id: "GENESIS".to_string(),
            body: EventBody::PolicyUpdate(policy),
        };
        let signed = SignedEvent::sign_new(unsigned, &self.keypair)?;
        self.repo.append_signed_event(&signed, Some(&self.cipher))?;
        Ok(signed)
    }

    pub fn submit_policy_update(&mut self, new_policy: PolicyPayload) -> CoreResult<SignedEvent> {
        let proj = self.repo.project_group(&self.group_id)?;
        let (seq, prev_ev) = self
            .repo
            .next_device_sequence(&self.group_id, &self.device_id)?;
        let unsigned = UnsignedEvent {
            schema_version: CURRENT_SCHEMA_VERSION,
            group_id: self.group_id.clone(),
            author_member_id: self.member_id.clone(),
            author_public_key: self.keypair.public_key_b64(),
            device_id: self.device_id.clone(),
            sequence: seq,
            previous_event_id: prev_ev,
            policy_version_id: proj.active_policy_event_id,
            body: EventBody::PolicyUpdate(new_policy),
        };
        let signed = SignedEvent::sign_new(unsigned, &self.keypair)?;
        self.repo.append_signed_event(&signed, Some(&self.cipher))?;
        Ok(signed)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn submit_expense_revision(
        &mut self,
        expense_id: &str,
        parent_revision_event_ids: Vec<String>,
        currency: &str,
        total_minor: i64,
        payers: Vec<PayerContribution>,
        split_rule: SplitRule,
        title: &str,
        note: &str,
        revision_reason: &str,
        attachment_refs: Vec<AttachmentRef>,
        voided: bool,
    ) -> CoreResult<SignedEvent> {
        self.submit_expense_revision_with_details(expense_id, parent_revision_event_ids,
            currency, total_minor, payers, split_rule, title, note, revision_reason,
            attachment_refs, voided, None)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn submit_expense_revision_with_details(
        &mut self,
        expense_id: &str,
        parent_revision_event_ids: Vec<String>,
        currency: &str,
        total_minor: i64,
        payers: Vec<PayerContribution>,
        split_rule: SplitRule,
        title: &str,
        note: &str,
        revision_reason: &str,
        attachment_refs: Vec<AttachmentRef>,
        voided: bool,
        details: Option<crate::domain::ExpenseDetails>,
    ) -> CoreResult<SignedEvent> {
        let details = match details {
            Some(details) => Some(details),
            None => crate::storage::expense_details_from_parents(
                &self.repo.list_events(&self.group_id)?, expense_id, &parent_revision_event_ids)?,
        };
        let proj = self.repo.project_group(&self.group_id)?;
        let resolved_shares = compute_resolved_shares(total_minor, &split_rule, voided)?;
        let attribution_matrix =
            compute_attribution_matrix(total_minor, &payers, &resolved_shares, voided)?;

        let payload = ExpenseRevisionPayload {
            expense_id: expense_id.to_string(),
            parent_revision_event_ids,
            currency: currency.to_string(),
            total_minor,
            payers,
            split_rule,
            resolved_shares,
            attribution_matrix,
            attribution_rule_version: ATTRIBUTION_RULE_VERSION.to_string(),
            details,
            title: title.to_string(),
            note: note.to_string(),
            revision_reason: revision_reason.to_string(),
            attachment_refs,
            voided,
        };

        let (seq, prev_ev) = self
            .repo
            .next_device_sequence(&self.group_id, &self.device_id)?;
        let unsigned = UnsignedEvent {
            schema_version: CURRENT_SCHEMA_VERSION,
            group_id: self.group_id.clone(),
            author_member_id: self.member_id.clone(),
            author_public_key: self.keypair.public_key_b64(),
            device_id: self.device_id.clone(),
            sequence: seq,
            previous_event_id: prev_ev,
            policy_version_id: proj.active_policy_event_id,
            body: EventBody::ExpenseUpsert(payload),
        };
        let signed = SignedEvent::sign_new(unsigned, &self.keypair)?;
        self.repo.append_signed_event(&signed, Some(&self.cipher))?;
        Ok(signed)
    }

    pub fn submit_custom_category(
        &mut self,
        category_id: &str,
        icon: &str,
        name: &str,
        deleted: bool,
    ) -> CoreResult<SignedEvent> {
        let proj = self.repo.project_group(&self.group_id)?;
        let (seq, prev_ev) = self
            .repo
            .next_device_sequence(&self.group_id, &self.device_id)?;
        let payload = CustomCategoryUpsertPayload {
            category_id: category_id.to_string(),
            icon: icon.to_string(),
            name: name.to_string(),
            deleted,
            observed_add_event_ids: if deleted {
                crate::storage::observed_category_tags(&self.repo.list_events(&self.group_id)?, category_id, name)
            } else { Vec::new() },
        };
        let unsigned = UnsignedEvent {
            schema_version: CURRENT_SCHEMA_VERSION,
            group_id: self.group_id.clone(),
            author_member_id: self.member_id.clone(),
            author_public_key: self.keypair.public_key_b64(),
            device_id: self.device_id.clone(),
            sequence: seq,
            previous_event_id: prev_ev,
            policy_version_id: proj.active_policy_event_id,
            body: EventBody::CategoryUpsert(payload),
        };
        let signed = SignedEvent::sign_new(unsigned, &self.keypair)?;
        self.repo.append_signed_event(&signed, Some(&self.cipher))?;
        Ok(signed)
    }

    pub fn declare_repayment(
        &mut self,
        payment_id: &str,
        payer_id: &str,
        payee_id: &str,
        currency: &str,
        amount_minor: i64,
        target_obligation_id: Option<String>,
        note: &str,
    ) -> CoreResult<SignedEvent> {
        let proj = self.repo.project_group(&self.group_id)?;
        let (seq, prev_ev) = self
            .repo
            .next_device_sequence(&self.group_id, &self.device_id)?;
        let payload = RepaymentDeclarePayload {
            payment_id: payment_id.to_string(),
            payer_id: payer_id.to_string(),
            payee_id: payee_id.to_string(),
            currency: currency.to_string(),
            amount_minor,
            target_obligation_id,
            external_reference: None,
            note: note.to_string(),
        };
        let unsigned = UnsignedEvent {
            schema_version: CURRENT_SCHEMA_VERSION,
            group_id: self.group_id.clone(),
            author_member_id: self.member_id.clone(),
            author_public_key: self.keypair.public_key_b64(),
            device_id: self.device_id.clone(),
            sequence: seq,
            previous_event_id: prev_ev,
            policy_version_id: proj.active_policy_event_id,
            body: EventBody::RepaymentDeclare(payload),
        };
        let signed = SignedEvent::sign_new(unsigned, &self.keypair)?;
        self.repo.append_signed_event(&signed, Some(&self.cipher))?;
        Ok(signed)
    }

    pub fn confirm_repayment(
        &mut self,
        payment_id: &str,
        declare_event_id: &str,
        overpayment_policy: Option<String>,
    ) -> CoreResult<SignedEvent> {
        let proj = self.repo.project_group(&self.group_id)?;
        let (seq, prev_ev) = self
            .repo
            .next_device_sequence(&self.group_id, &self.device_id)?;
        let payload = RepaymentConfirmPayload {
            payment_id: payment_id.to_string(),
            declare_event_id: declare_event_id.to_string(),
            overpayment_policy,
        };
        let unsigned = UnsignedEvent {
            schema_version: CURRENT_SCHEMA_VERSION,
            group_id: self.group_id.clone(),
            author_member_id: self.member_id.clone(),
            author_public_key: self.keypair.public_key_b64(),
            device_id: self.device_id.clone(),
            sequence: seq,
            previous_event_id: prev_ev,
            policy_version_id: proj.active_policy_event_id,
            body: EventBody::RepaymentConfirm(payload),
        };
        let signed = SignedEvent::sign_new(unsigned, &self.keypair)?;
        self.repo.append_signed_event(&signed, Some(&self.cipher))?;
        Ok(signed)
    }

    pub fn map_late_repayment(
        &mut self,
        payment_id: &str,
        target_obligation_id: &str,
        note: &str,
    ) -> CoreResult<SignedEvent> {
        let proj = self.repo.project_group(&self.group_id)?;
        let (seq, prev_ev) = self
            .repo
            .next_device_sequence(&self.group_id, &self.device_id)?;
        let payload = RepaymentMapObligationPayload {
            payment_id: payment_id.to_string(),
            target_obligation_id: target_obligation_id.to_string(),
            note: note.to_string(),
        };
        let unsigned = UnsignedEvent {
            schema_version: CURRENT_SCHEMA_VERSION,
            group_id: self.group_id.clone(),
            author_member_id: self.member_id.clone(),
            author_public_key: self.keypair.public_key_b64(),
            device_id: self.device_id.clone(),
            sequence: seq,
            previous_event_id: prev_ev,
            policy_version_id: proj.active_policy_event_id,
            body: EventBody::RepaymentMapObligation(payload),
        };
        let signed = SignedEvent::sign_new(unsigned, &self.keypair)?;
        self.repo.append_signed_event(&signed, Some(&self.cipher))?;
        Ok(signed)
    }

    /// Local read-only preview of any of the 4 settlement modes without creating an event (AC-S03).
    pub fn preview_settlement(
        &self,
        mode: SettlementMode,
        settlement_currency: Option<&str>,
        fx_rates: &[FxRateSpec],
    ) -> CoreResult<SettlementComputationResult> {
        let events = self.repo.list_events(&self.group_id)?;
        let proj = build_projection(&self.group_id, &events)?;
        let open_debts = proj.open_pair_debts_with_history(&events)?;
        let all_participants: BTreeSet<String> =
            proj.active_policy.participants.keys().cloned().collect();
        compute_settlement_from_pair_debts(
            &all_participants,
            &proj.active_policy.currencies,
            &open_debts,
            mode,
            settlement_currency,
            fx_rates,
        )
    }

    /// Proposes a formal settlement snapshot freezing covered expenses, repayments, FX rates, and transfers.
    pub fn propose_settlement_snapshot(
        &mut self,
        snapshot_id: &str,
        mode: SettlementMode,
        settlement_currency: Option<&str>,
        fx_rates: Vec<FxRateSpec>,
    ) -> CoreResult<SignedEvent> {
        let events = self.repo.list_events(&self.group_id)?;
        let proj = build_projection(&self.group_id, &events)?;

        proj.ensure_formal_settlement_ready()?;

        let open_debts = proj.open_pair_debts_with_history(&events)?;
        let all_participants: BTreeSet<String> =
            proj.active_policy.participants.keys().cloned().collect();
        let calc = compute_settlement_from_pair_debts(
            &all_participants,
            &proj.active_policy.currencies,
            &open_debts,
            mode,
            settlement_currency,
            &fx_rates,
        )?;

        let mut covered_expense_revisions = BTreeMap::new();
        for (exp_id, exp_item) in &proj.expenses {
            if let Some(rev_id) = &exp_item.active_revision_event_id {
                covered_expense_revisions.insert(exp_id.clone(), rev_id.clone());
            }
        }

        let covered_repayment_ids: Vec<String> = proj
            .repayments
            .iter()
            .filter(|(_, r)| {
                r.status == RepaymentStatus::ConfirmedByBoth && r.applied_to_obligation_id.is_none()
            })
            .map(|(id, _)| id.clone())
            .collect();

        let novated_obligation_ids: Vec<String> = proj
            .active_obligations
            .values()
            .filter(|ob| ob.remaining_minor() > 0)
            .map(|ob| ob.obligation_id.clone())
            .collect();

        // Required approvers = all participants involved in any open pairwise debt or resulting transfer.
        let mut required_approvers = BTreeSet::new();
        for pair_map in open_debts.values() {
            for ((u, v), &amt) in pair_map {
                if amt != 0 {
                    required_approvers.insert(u.clone());
                    required_approvers.insert(v.clone());
                }
            }
        }
        for tr in &calc.transfers {
            required_approvers.insert(tr.debtor_id.clone());
            required_approvers.insert(tr.creditor_id.clone());
        }

        let mut snap = SettlementSnapshotPayload {
            snapshot_id: snapshot_id.to_string(),
            previous_commit_event_id: proj.latest_commit_event_id.clone(),
            mode,
            settlement_currency: calc.settlement_currency,
            fx_rates,
            covered_expense_revisions,
            covered_repayment_ids,
            novated_obligation_ids,
            net_balances_by_currency: calc.net_balances_by_currency,
            transfers: calc.transfers,
            optimality: calc.optimality,
            algorithm_version: SETTLEMENT_ALGORITHM_VERSION.to_string(),
            required_approvers,
            snapshot_digest: String::new(),
        };
        snap.snapshot_digest = compute_snapshot_digest(&snap)?;

        let (seq, prev_ev) = self
            .repo
            .next_device_sequence(&self.group_id, &self.device_id)?;
        let unsigned = UnsignedEvent {
            schema_version: CURRENT_SCHEMA_VERSION,
            group_id: self.group_id.clone(),
            author_member_id: self.member_id.clone(),
            author_public_key: self.keypair.public_key_b64(),
            device_id: self.device_id.clone(),
            sequence: seq,
            previous_event_id: prev_ev,
            policy_version_id: proj.active_policy_event_id,
            body: EventBody::SettlementPropose(snap),
        };
        let signed = SignedEvent::sign_new(unsigned, &self.keypair)?;
        self.repo.append_signed_event(&signed, Some(&self.cipher))?;
        Ok(signed)
    }

    pub fn approve_settlement_snapshot(&mut self, snapshot_id: &str) -> CoreResult<SignedEvent> {
        let proj = self.repo.project_group(&self.group_id)?;
        proj.ensure_formal_settlement_ready()?;
        proj.ensure_snapshot_current(snapshot_id)?;
        let snap_item = proj.snapshots.get(snapshot_id).ok_or_else(|| {
            CoreError::NotFound(format!("snapshot '{snapshot_id}' not found"))
        })?;
        let payload = SettlementApprovePayload {
            snapshot_id: snapshot_id.to_string(),
            snapshot_digest: snap_item.snapshot.snapshot_digest.clone(),
            approver_participant_id: self.member_id.clone(),
        };
        let (seq, prev_ev) = self
            .repo
            .next_device_sequence(&self.group_id, &self.device_id)?;
        let unsigned = UnsignedEvent {
            schema_version: CURRENT_SCHEMA_VERSION,
            group_id: self.group_id.clone(),
            author_member_id: self.member_id.clone(),
            author_public_key: self.keypair.public_key_b64(),
            device_id: self.device_id.clone(),
            sequence: seq,
            previous_event_id: prev_ev,
            policy_version_id: proj.active_policy_event_id,
            body: EventBody::SettlementApprove(payload),
        };
        let signed = SignedEvent::sign_new(unsigned, &self.keypair)?;
        self.repo.append_signed_event(&signed, Some(&self.cipher))?;
        Ok(signed)
    }

    pub fn commit_settlement_snapshot(&mut self, snapshot_id: &str) -> CoreResult<SignedEvent> {
        let proj = self.repo.project_group(&self.group_id)?;
        proj.ensure_formal_settlement_ready()?;
        proj.ensure_snapshot_current(snapshot_id)?;
        let snap_item = proj.snapshots.get(snapshot_id).ok_or_else(|| {
            CoreError::NotFound(format!("snapshot '{snapshot_id}' not found"))
        })?;
        let approval_event_ids: Vec<String> = snap_item.approved_by.values().cloned().collect();
        let obligations: Vec<SettlementObligation> = snap_item
            .snapshot
            .transfers
            .iter()
            .enumerate()
            .map(|(idx, tr)| {
                let ob_seed = format!(
                    "{}:{}:{}:{}:{}",
                    snapshot_id, idx, tr.debtor_id, tr.creditor_id, tr.currency
                );
                SettlementObligation {
                    obligation_id: format!(
                        "ob_{}_{idx:03}_{}",
                        snapshot_id,
                        &blake3_hash_b64(ob_seed.as_bytes())[..8]
                    ),
                    snapshot_id: snapshot_id.to_string(),
                    debtor_id: tr.debtor_id.clone(),
                    creditor_id: tr.creditor_id.clone(),
                    currency: tr.currency.clone(),
                    total_amount_minor: tr.amount_minor,
                    paid_amount_minor: 0,
                }
            })
            .collect();

        let payload = SettlementCommitPayload {
            snapshot_id: snapshot_id.to_string(),
            snapshot_digest: snap_item.snapshot.snapshot_digest.clone(),
            previous_commit_event_id: snap_item.snapshot.previous_commit_event_id.clone(),
            approval_event_ids,
            obligations,
        };
        let (seq, prev_ev) = self
            .repo
            .next_device_sequence(&self.group_id, &self.device_id)?;
        let unsigned = UnsignedEvent {
            schema_version: CURRENT_SCHEMA_VERSION,
            group_id: self.group_id.clone(),
            author_member_id: self.member_id.clone(),
            author_public_key: self.keypair.public_key_b64(),
            device_id: self.device_id.clone(),
            sequence: seq,
            previous_event_id: prev_ev,
            policy_version_id: proj.active_policy_event_id,
            body: EventBody::SettlementCommit(payload),
        };
        let signed = SignedEvent::sign_new(unsigned, &self.keypair)?;
        self.repo.append_signed_event(&signed, Some(&self.cipher))?;
        Ok(signed)
    }

    /// Exports all or selected missing events as an encrypted `.tripdelta` byte payload.
    pub fn export_tripdelta_bytes(
        &self,
        peer_summary: Option<&PeerSyncSummary>,
    ) -> CoreResult<Vec<u8>> {
        let events = match peer_summary {
            Some(summary) => self
                .repo
                .select_events_missing_on_peer(&self.group_id, summary)?,
            None => self.repo.list_events(&self.group_id)?,
        };
        let pkg = TripDeltaPackage::pack_events(&self.group_id, &events, &self.cipher)?;
        pkg.to_bytes()
    }

    pub fn import_tripdelta_bytes(&mut self, bytes: &[u8]) -> CoreResult<BatchImportSummary> {
        let pkg = TripDeltaPackage::from_bytes(bytes)?;
        let events = pkg.unpack_events(&self.group_id, &self.cipher)?;
        self.repo
            .import_event_batch(&self.group_id, &events, Some(&self.cipher))
    }

    /// Performs a bidirectional LAN incremental sync with another `LedgerNode`.
    pub fn sync_lan_with_peer(
        &mut self,
        peer: &mut LedgerNode,
    ) -> CoreResult<(BatchImportSummary, BatchImportSummary)> {
        let my_summary = self.repo.build_sync_summary(&self.group_id)?;
        let peer_summary = peer.repo.build_sync_summary(&peer.group_id)?;

        let to_peer = self
            .repo
            .select_events_missing_on_peer(&self.group_id, &peer_summary)?;
        let to_me = peer
            .repo
            .select_events_missing_on_peer(&peer.group_id, &my_summary)?;

        let peer_import =
            peer.repo
                .import_event_batch(&peer.group_id, &to_peer, Some(&peer.cipher))?;
        let my_import =
            self.repo
                .import_event_batch(&self.group_id, &to_me, Some(&self.cipher))?;

        let _ = canonical_json_bytes(&my_summary)?;
        Ok((my_import, peer_import))
    }
}

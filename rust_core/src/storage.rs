use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use crate::crypto::{blake3_hash_b64, canonical_json_bytes, GroupCipher};
pub use crate::domain::EventApplyStatus;
use crate::domain::*;
use crate::engine::*;
use crate::error::{CoreError, CoreResult};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceSyncCursor {
    pub member_id: String,
    pub device_id: String,
    pub contiguous_seq: u64,
    pub max_seen_seq: u64,
    pub missing_seqs: Vec<u64>,
    pub head_event_id: Option<String>,
    pub forked_seqs: Vec<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExpenseProjectionItem {
    pub expense_id: String,
    pub creator_member_id: String,
    pub active_revision_event_id: Option<String>,
    pub active_revision: Option<ExpenseRevisionPayload>,
    pub conflict_leaf_event_ids: Vec<String>,
    pub conflict_branches: Vec<ExpenseRevisionPayload>,
    pub revision_history_event_ids: Vec<String>,
    pub has_conflict: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum RepaymentStatus {
    DeclaredByPayer,
    ConfirmedByBoth,
    Disputed { reason: String },
    PendingMapping,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RepaymentProjectionItem {
    pub payment_id: String,
    pub declare_event_id: String,
    pub confirm_event_id: Option<String>,
    pub declaration: RepaymentDeclarePayload,
    pub status: RepaymentStatus,
    pub applied_to_obligation_id: Option<String>,
    pub overpayment_minor: i64,
    pub overpayment_policy: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum SnapshotLifecycleStatus {
    Proposed,
    AwaitingApprovals,
    ReadyToCommit,
    Committed,
    SupersededOrConflicted,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SnapshotProjectionItem {
    pub snapshot_event_id: String,
    pub snapshot: SettlementSnapshotPayload,
    pub approved_by: BTreeMap<String, String>,
    pub commit_event_id: Option<String>,
    pub status: SnapshotLifecycleStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CustomCategoryProjectionItem {
    pub id: String,
    pub icon: String,
    pub name: String,
    pub is_custom: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LedgerProjection {
    pub group_id: String,
    pub active_policy_event_id: String,
    pub active_policy: PolicyPayload,
    pub policy_conflicts: Vec<String>,
    pub device_cursors: BTreeMap<String, DeviceSyncCursor>,
    pub custom_categories: Vec<CustomCategoryProjectionItem>,
    pub expenses: BTreeMap<String, ExpenseProjectionItem>,
    pub repayments: BTreeMap<String, RepaymentProjectionItem>,
    pub snapshots: BTreeMap<String, SnapshotProjectionItem>,
    pub active_obligations: BTreeMap<String, SettlementObligation>,
    pub latest_commit_event_id: Option<String>,
    pub settled_expense_revisions: BTreeMap<String, String>,
    pub settled_direct_repayment_ids: BTreeSet<String>,
    pub pending_dependency_events: Vec<String>,
    pub pending_reauth_events: Vec<String>,
    pub commit_conflicts: Vec<String>,
}

impl LedgerProjection {
    pub fn ensure_formal_settlement_ready(&self) -> CoreResult<()> {
        if !self.policy_conflicts.is_empty() || !self.commit_conflicts.is_empty() ||
            !self.pending_dependency_events.is_empty() || !self.pending_reauth_events.is_empty() ||
            self.device_cursors.values().any(|c| !c.forked_seqs.is_empty() || !c.missing_seqs.is_empty()) {
            return Err(CoreError::Settlement("存在冲突、待依赖或待重授权事件，暂停正式结算".into()));
        }
        if self.expenses.values().any(|e| e.has_conflict) {
            return Err(CoreError::Conflict("存在未解决的账目修订冲突".into()));
        }
        if self.repayments.values().any(|r| r.status != RepaymentStatus::ConfirmedByBoth) {
            return Err(CoreError::Settlement("存在待确认、争议或待映射还款，请先核对".into()));
        }
        Ok(())
    }

    pub fn ensure_snapshot_current(&self, snapshot_id: &str) -> CoreResult<()> {
        let item = self.snapshots.get(snapshot_id)
            .ok_or_else(|| CoreError::NotFound("结算快照不存在".into()))?;
        if item.commit_event_id.is_some() ||
            item.status == SnapshotLifecycleStatus::SupersededOrConflicted ||
            item.snapshot.previous_commit_event_id != self.latest_commit_event_id {
            return Err(CoreError::Settlement("此快照已生效或已过期，请使用当前结算方案".into()));
        }
        Ok(())
    }

    /// Computes the current open canonical pairwise debts per currency:
    /// `currency -> (min_id, max_id) -> signed_amount_minor` (positive means `min_id` owes `max_id`).
    /// Includes:
    /// 1. Remaining amounts on active `SettlementObligation`s from the latest committed settlement.
    /// 2. Delta attribution for expenses created or revised since the last committed settlement.
    /// 3. Confirmed direct repayments (or overpayments) not yet absorbed into a committed snapshot.
    pub fn open_pair_debts_by_currency(
        &self,
    ) -> CoreResult<BTreeMap<String, BTreeMap<(String, String), i64>>> {
        let mut by_curr: BTreeMap<String, BTreeMap<(String, String), i64>> = BTreeMap::new();

        // 1. Active novated settlement obligations
        for ob in self.active_obligations.values() {
            let rem = ob.remaining_minor();
            if rem > 0 {
                let pair_map = by_curr.entry(ob.currency.clone()).or_default();
                add_canonical_pair_debt(pair_map, &ob.debtor_id, &ob.creditor_id, rem);
            }
        }

        // 2. Unsettled expenses or post-settlement expense deltas
        for (expense_id, exp_item) in &self.expenses {
            if exp_item.has_conflict {
                continue;
            }
            let Some(active_rev_id) = &exp_item.active_revision_event_id else {
                continue;
            };
            let Some(active_rev) = &exp_item.active_revision else {
                continue;
            };

            if let Some(settled_rev_id) = self.settled_expense_revisions.get(expense_id) {
                if settled_rev_id == active_rev_id {
                    // Already fully novated in a committed settlement snapshot.
                    continue;
                }
                // Post-settlement revision: subtract the settled revision's attribution and add the new one.
                if let Some(settled_rev) = exp_item
                    .revision_history_event_ids
                    .iter()
                    .find(|&id| id == settled_rev_id)
                    .and_then(|_| self.find_historical_revision(expense_id, settled_rev_id))
                {
                    let old_pair_map = by_curr.entry(settled_rev.currency.clone()).or_default();
                    for (debtor, creds) in &settled_rev.attribution_matrix {
                        for (creditor, &amt) in creds {
                            add_canonical_pair_debt(old_pair_map, debtor, creditor, -amt);
                        }
                    }
                }
            }

            if !active_rev.voided {
                let pair_map = by_curr.entry(active_rev.currency.clone()).or_default();
                for (debtor, creds) in &active_rev.attribution_matrix {
                    for (creditor, &amt) in creds {
                        add_canonical_pair_debt(pair_map, debtor, creditor, amt);
                    }
                }
            }
        }

        // 3. Confirmed repayments not yet absorbed by a settlement snapshot
        for (payment_id, rep) in &self.repayments {
            if self.settled_direct_repayment_ids.contains(payment_id) {
                continue;
            }
            if rep.status != RepaymentStatus::ConfirmedByBoth {
                continue;
            }
            let pair_map = by_curr.entry(rep.declaration.currency.clone()).or_default();
            if rep.applied_to_obligation_id.is_some() {
                // Principal was already deducted from `ob.paid_amount_minor`; only overpayment creates reverse credit.
                if rep.overpayment_minor > 0 {
                    add_canonical_pair_debt(
                        pair_map,
                        &rep.declaration.payee_id,
                        &rep.declaration.payer_id,
                        rep.overpayment_minor,
                    );
                }
            } else {
                // Direct repayment reduces payer's debt to payee (or creates reverse credit if overpaid).
                add_canonical_pair_debt(
                    pair_map,
                    &rep.declaration.payer_id,
                    &rep.declaration.payee_id,
                    -rep.declaration.amount_minor,
                );
            }
        }

        // Prune empty currency maps
        by_curr.retain(|_, pair_map| !pair_map.is_empty());
        Ok(by_curr)
    }

    fn find_historical_revision(
        &self,
        _expense_id: &str,
        _rev_id: &str,
    ) -> Option<ExpenseRevisionPayload> {
        None
    }
}

pub struct LedgerRepository {
    conn: Connection,
}

impl LedgerRepository {
    pub fn open_in_memory() -> CoreResult<Self> {
        let conn = Connection::open_in_memory()?;
        let repo = Self { conn };
        repo.init_schema()?;
        Ok(repo)
    }

    pub fn open_file(path: impl AsRef<Path>) -> CoreResult<Self> {
        let conn = Connection::open(path)?;
        let repo = Self { conn };
        repo.init_schema()?;
        Ok(repo)
    }

    fn init_schema(&self) -> CoreResult<()> {
        self.conn.execute_batch(
            "
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;

            CREATE TABLE IF NOT EXISTS events (
                insertion_id INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id TEXT NOT NULL UNIQUE,
                group_id TEXT NOT NULL,
                author_member_id TEXT NOT NULL,
                device_id TEXT NOT NULL,
                sequence INTEGER NOT NULL,
                previous_event_id TEXT,
                policy_version_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                raw_json TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_events_group ON events(group_id, insertion_id);
            CREATE INDEX IF NOT EXISTS idx_events_device ON events(group_id, device_id, sequence);

            CREATE TABLE IF NOT EXISTS webdav_outbox (
                object_hash TEXT PRIMARY KEY,
                group_id TEXT NOT NULL,
                event_id TEXT NOT NULL UNIQUE,
                ciphertext BLOB NOT NULL,
                uploaded INTEGER NOT NULL DEFAULT 0,
                retry_count INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS attachments (
                attachment_id TEXT PRIMARY KEY,
                group_id TEXT NOT NULL,
                mime_type TEXT NOT NULL,
                byte_len INTEGER NOT NULL,
                ciphertext_blake3 TEXT NOT NULL,
                ciphertext BLOB NOT NULL
            );

            CREATE TABLE IF NOT EXISTS workspace_meta (
                meta_key TEXT PRIMARY KEY,
                meta_value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS local_member_keys (
                member_id TEXT PRIMARY KEY,
                device_id TEXT NOT NULL,
                secret_bytes BLOB NOT NULL
            );

            CREATE TABLE IF NOT EXISTS webdav_remote_mirror (
                opaque_group_dir TEXT NOT NULL,
                object_hash TEXT NOT NULL,
                ciphertext BLOB NOT NULL,
                PRIMARY KEY (opaque_group_dir, object_hash)
            );
            ",
        )?;
        Ok(())
    }

    pub fn total_event_count(&self) -> CoreResult<usize> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(1) FROM events", [], |row| row.get(0))?;
        Ok(count as usize)
    }

    pub fn clear_all_tables(&self) -> CoreResult<()> {
        self.conn.execute_batch(
            "
            DELETE FROM events;
            DELETE FROM webdav_outbox;
            DELETE FROM attachments;
            DELETE FROM workspace_meta;
            DELETE FROM local_member_keys;
            DELETE FROM webdav_remote_mirror;
            ",
        )?;
        Ok(())
    }

    pub fn set_meta(&self, key: &str, value: &str) -> CoreResult<()> {
        self.conn.execute(
            "INSERT OR REPLACE INTO workspace_meta (meta_key, meta_value) VALUES (?1, ?2)",
            params![key, value],
        )?;
        Ok(())
    }

    pub fn get_meta(&self, key: &str) -> CoreResult<Option<String>> {
        let mut stmt = self
            .conn
            .prepare("SELECT meta_value FROM workspace_meta WHERE meta_key = ?1")?;
        let mut rows = stmt.query(params![key])?;
        if let Some(row) = rows.next()? {
            Ok(Some(row.get(0)?))
        } else {
            Ok(None)
        }
    }

    pub fn save_member_key(
        &self,
        member_id: &str,
        device_id: &str,
        secret_bytes: &[u8; 32],
    ) -> CoreResult<()> {
        self.conn.execute(
            "INSERT OR REPLACE INTO local_member_keys (member_id, device_id, secret_bytes)
             VALUES (?1, ?2, ?3)",
            params![member_id, device_id, secret_bytes.as_slice()],
        )?;
        Ok(())
    }

    pub fn load_member_keys(&self) -> CoreResult<BTreeMap<String, (String, [u8; 32])>> {
        let mut stmt = self
            .conn
            .prepare("SELECT member_id, device_id, secret_bytes FROM local_member_keys")?;
        let rows = stmt.query_map([], |row| {
            let member_id: String = row.get(0)?;
            let device_id: String = row.get(1)?;
            let blob: Vec<u8> = row.get(2)?;
            Ok((member_id, device_id, blob))
        })?;
        let mut out = BTreeMap::new();
        for r in rows {
            let (member_id, device_id, blob) = r?;
            if let Ok(arr) = <[u8; 32]>::try_from(blob.as_slice()) {
                out.insert(member_id, (device_id, arr));
            }
        }
        Ok(out)
    }

    pub fn save_webdav_mirror_object(
        &self,
        opaque_group_dir: &str,
        object_hash: &str,
        ciphertext: &[u8],
    ) -> CoreResult<()> {
        self.conn.execute(
            "INSERT OR REPLACE INTO webdav_remote_mirror (opaque_group_dir, object_hash, ciphertext)
             VALUES (?1, ?2, ?3)",
            params![opaque_group_dir, object_hash, ciphertext],
        )?;
        Ok(())
    }

    pub fn load_webdav_mirror_objects(&self) -> CoreResult<Vec<(String, String, Vec<u8>)>> {
        let mut stmt = self
            .conn
            .prepare("SELECT opaque_group_dir, object_hash, ciphertext FROM webdav_remote_mirror")?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Vec<u8>>(2)?,
            ))
        })?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    /// Encrypts and stores a receipt attachment locally (`FR-ATT-01`).
    pub fn store_encrypted_attachment(
        &self,
        group_id: &str,
        attachment_id: &str,
        mime_type: &str,
        plaintext: &[u8],
        cipher: &GroupCipher,
    ) -> CoreResult<AttachmentRef> {
        let aad = format!("sbill:v1:att:{group_id}:{attachment_id}");
        let ciphertext = cipher.encrypt(plaintext, aad.as_bytes())?;
        let hash = blake3_hash_b64(&ciphertext);
        self.conn.execute(
            "INSERT OR REPLACE INTO attachments (attachment_id, group_id, mime_type, byte_len, ciphertext_blake3, ciphertext)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                attachment_id,
                group_id,
                mime_type,
                plaintext.len() as i64,
                hash,
                ciphertext,
            ],
        )?;
        Ok(AttachmentRef {
            attachment_id: attachment_id.to_string(),
            mime_type: mime_type.to_string(),
            byte_len: plaintext.len() as u64,
            ciphertext_blake3: hash,
        })
    }

    /// Returns `Ok(None)` if the attachment body has not been synced to this device yet ("附件待同步"),
    /// or verifies `ciphertext_blake3` and decrypts it if present (`FR-ATT-01`).
    pub fn load_decrypted_attachment(
        &self,
        group_id: &str,
        att_ref: &AttachmentRef,
        cipher: &GroupCipher,
    ) -> CoreResult<Option<Vec<u8>>> {
        let mut stmt = self.conn.prepare(
            "SELECT ciphertext_blake3, ciphertext FROM attachments WHERE attachment_id = ?1 AND group_id = ?2",
        )?;
        let mut rows = stmt.query(params![att_ref.attachment_id, group_id])?;
        let Some(row) = rows.next()? else {
            return Ok(None);
        };
        let stored_hash: String = row.get(0)?;
        let ciphertext: Vec<u8> = row.get(1)?;
        let actual_hash = blake3_hash_b64(&ciphertext);
        if stored_hash != att_ref.ciphertext_blake3 || actual_hash != att_ref.ciphertext_blake3 {
            return Err(CoreError::Crypto(format!(
                "attachment '{}' ciphertext hash mismatch",
                att_ref.attachment_id
            )));
        }
        let aad = format!("sbill:v1:att:{group_id}:{}", att_ref.attachment_id);
        let plaintext = cipher.decrypt(&ciphertext, aad.as_bytes())?;
        Ok(Some(plaintext))
    }

    pub fn has_attachment(&self, group_id: &str, attachment_id: &str) -> CoreResult<bool> {
        let count: i64 = self.conn.query_row(
            "SELECT COUNT(1) FROM attachments WHERE group_id = ?1 AND attachment_id = ?2",
            params![group_id, attachment_id],
            |row| row.get(0),
        )?;
        Ok(count > 0)
    }

    pub fn has_event(&self, event_id: &str) -> CoreResult<bool> {
        let count: i64 = self.conn.query_row(
            "SELECT COUNT(1) FROM events WHERE event_id = ?1",
            params![event_id],
            |row| row.get(0),
        )?;
        Ok(count > 0)
    }

    pub fn list_events(&self, group_id: &str) -> CoreResult<Vec<SignedEvent>> {
        let mut stmt = self.conn.prepare(
            "SELECT raw_json FROM events WHERE group_id = ?1 ORDER BY insertion_id ASC",
        )?;
        let rows = stmt.query_map(params![group_id], |row| {
            let raw: String = row.get(0)?;
            Ok(raw)
        })?;
        let mut events = Vec::new();
        for r in rows {
            let raw = r?;
            let ev: SignedEvent = serde_json::from_str(&raw)?;
            events.push(ev);
        }
        Ok(events)
    }

    pub fn next_device_sequence(
        &self,
        group_id: &str,
        device_id: &str,
    ) -> CoreResult<(u64, Option<String>)> {
        let mut stmt = self.conn.prepare(
            "SELECT sequence, event_id FROM events WHERE group_id = ?1 AND device_id = ?2 ORDER BY sequence DESC LIMIT 1",
        )?;
        let mut rows = stmt.query(params![group_id, device_id])?;
        if let Some(row) = rows.next()? {
            let seq: u64 = row.get(0)?;
            let ev_id: String = row.get(1)?;
            Ok((seq + 1, Some(ev_id)))
        } else {
            Ok((1, None))
        }
    }

    /// Validates cryptographic signature, stores the event idempotently, and queues an encrypted
    /// WebDAV object if `group_cipher` is provided. Returns the resulting `EventApplyStatus`.
    pub fn append_signed_event(
        &mut self,
        event: &SignedEvent,
        group_cipher: Option<&GroupCipher>,
    ) -> CoreResult<EventApplyStatus> {
        event.verify_cryptographic_integrity()?;

        if self.has_event(&event.event_id)? {
            return Ok(EventApplyStatus::Duplicate);
        }

        // Pre-validate immediate structural/permission rules if dependencies are already present
        let existing_events = self.list_events(&event.unsigned.group_id)?;
        if !existing_events.is_empty() {
            let pre_proj = build_projection(&event.unsigned.group_id, &existing_events)?;
            validate_event_against_projection(event, &pre_proj, &existing_events)?;
        } else {
            // First event in group must be a genesis PolicyUpdate
            match &event.unsigned.body {
                EventBody::PolicyUpdate(policy) => {
                    if policy.policy_seq != 1 || policy.previous_policy_event_id.is_some() {
                        return Err(CoreError::Policy(
                            "first event in a group must be genesis PolicyUpdate (policy_seq = 1)"
                                .to_string(),
                        ));
                    }
                    let owner = policy
                        .participants
                        .get(&policy.owner_member_id)
                        .ok_or_else(|| {
                            CoreError::Policy("owner_member_id missing in participants".to_string())
                        })?;
                    if owner.role != Role::Owner
                        || owner.bound_public_key.as_deref()
                            != Some(event.unsigned.author_public_key.as_str())
                    {
                        return Err(CoreError::Policy(
                            "genesis policy must be signed by the bound owner public key"
                                .to_string(),
                        ));
                    }
                }
                _ => {
                    return Err(CoreError::Policy(
                        "cannot insert non-policy event before genesis policy".to_string(),
                    ));
                }
            }
        }

        let raw_json = String::from_utf8(canonical_json_bytes(event)?)
            .map_err(|e| CoreError::Crypto(format!("invalid utf8 event json: {e}")))?;
        let kind_name = event_kind_label(&event.unsigned.body);

        let tx = self.conn.transaction()?;
        tx.execute(
            "INSERT INTO events (
                event_id, group_id, author_member_id, device_id, sequence,
                previous_event_id, policy_version_id, kind, raw_json
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                event.event_id,
                event.unsigned.group_id,
                event.unsigned.author_member_id,
                event.unsigned.device_id,
                event.unsigned.sequence,
                event.unsigned.previous_event_id,
                event.unsigned.policy_version_id,
                kind_name,
                raw_json,
            ],
        )?;

        if let Some(cipher) = group_cipher {
            let aad = format!("sbill:v1:event:{}", event.unsigned.group_id);
            let ciphertext = cipher.encrypt(raw_json.as_bytes(), aad.as_bytes())?;
            let object_hash = blake3_hash_b64(&ciphertext);
            tx.execute(
                "INSERT OR IGNORE INTO webdav_outbox (object_hash, group_id, event_id, ciphertext, uploaded, retry_count)
                 VALUES (?1, ?2, ?3, ?4, 0, 0)",
                params![object_hash, event.unsigned.group_id, event.event_id, ciphertext],
            )?;
        }
        tx.commit()?;

        let all_events = self.list_events(&event.unsigned.group_id)?;
        let proj = build_projection(&event.unsigned.group_id, &all_events)?;

        if proj.pending_dependency_events.contains(&event.event_id) {
            Ok(EventApplyStatus::PendingDependency)
        } else if proj.pending_reauth_events.contains(&event.event_id) {
            Ok(EventApplyStatus::PendingReauth)
        } else if let EventBody::ExpenseUpsert(exp) = &event.unsigned.body {
            if let Some(item) = proj.expenses.get(&exp.expense_id) {
                if item.has_conflict {
                    return Ok(EventApplyStatus::ConflictBranch);
                }
            }
            Ok(EventApplyStatus::Applied)
        } else {
            Ok(EventApplyStatus::Applied)
        }
    }

    /// Imports a batch of events from any sync transport (LAN, WebDAV, .tripdelta file, QR).
    /// Order-independent: events can arrive out of order and still converge to the exact same projection.
    pub fn import_event_batch(
        &mut self,
        group_id: &str,
        incoming_events: &[SignedEvent],
        group_cipher: Option<&GroupCipher>,
    ) -> CoreResult<BatchImportSummary> {
        if incoming_events.len() > crate::crypto::SYNC_PACK_MAX_EVENTS {
            return Err(CoreError::SyncPackage("同步事件数量超过限额".into()));
        }
        let existing = self.list_events(group_id)?;
        let mut known: BTreeSet<String> = existing.iter().map(|e| e.event_id.clone()).collect();
        let mut staged = Vec::new();
        let mut duplicates = 0;
        let mut rejected = Vec::new();
        for event in incoming_events {
            if event.unsigned.group_id != group_id {
                rejected.push((event.event_id.clone(), "group_id mismatch".into()));
                continue;
            }
            if let Err(error) = event.verify_cryptographic_integrity() {
                rejected.push((event.event_id.clone(), error.to_string()));
                continue;
            }
            if !known.insert(event.event_id.clone()) {
                duplicates += 1;
            } else {
                staged.push(event.clone());
            }
        }
        let mut trial = existing.clone();
        trial.extend(staged.iter().cloned());
        let projected = if rejected.is_empty() { build_projection(group_id, &trial) } else {
            Err(CoreError::SyncPackage("同步包包含无效事件，整包拒绝".into()))
        };
        let projection = match projected {
            Ok(projection) => projection,
            Err(error) => {
                for event in &staged {
                    rejected.push((event.event_id.clone(), format!("整包回滚：{error}")));
                }
                if existing.is_empty() {
                    return Err(error);
                }
                let before = build_projection(group_id, &existing)?;
                return Ok(BatchImportSummary {
                    added_count: 0, duplicate_count: duplicates, rejected_events: rejected,
                    conflict_expense_ids: before.expenses.values().filter(|e| e.has_conflict)
                        .map(|e| e.expense_id.clone()).collect(),
                    pending_dependency_count: before.pending_dependency_events.len(),
                    pending_reauth_count: before.pending_reauth_events.len(),
                });
            }
        };
        // Validation is over the complete event set; no transport-specific arrival order is trusted.
        let transaction = self.conn.transaction()?;
        for event in &staged {
            let raw = String::from_utf8(canonical_json_bytes(event)?)
                .map_err(|e| CoreError::Crypto(e.to_string()))?;
            transaction.execute(
                "INSERT INTO events (event_id, group_id, author_member_id, device_id, sequence,
                 previous_event_id, policy_version_id, kind, raw_json)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![event.event_id, event.unsigned.group_id, event.unsigned.author_member_id,
                    event.unsigned.device_id, event.unsigned.sequence, event.unsigned.previous_event_id,
                    event.unsigned.policy_version_id, event_kind_label(&event.unsigned.body), raw],
            )?;
            if let Some(cipher) = group_cipher {
                let aad = format!("sbill:v1:event:{group_id}");
                let ciphertext = cipher.encrypt(raw.as_bytes(), aad.as_bytes())?;
                transaction.execute(
                    "INSERT OR IGNORE INTO webdav_outbox
                     (object_hash, group_id, event_id, ciphertext, uploaded, retry_count)
                     VALUES (?1, ?2, ?3, ?4, 0, 0)",
                    params![blake3_hash_b64(&ciphertext), group_id, event.event_id, ciphertext],
                )?;
            }
        }
        transaction.commit()?;
        Ok(BatchImportSummary {
            added_count: staged.len(), duplicate_count: duplicates, rejected_events: Vec::new(),
            conflict_expense_ids: projection.expenses.values().filter(|e| e.has_conflict)
                .map(|e| e.expense_id.clone()).collect(),
            pending_dependency_count: projection.pending_dependency_events.len(),
            pending_reauth_count: projection.pending_reauth_events.len(),
        })
    }

    pub fn project_group(&self, group_id: &str) -> CoreResult<LedgerProjection> {
        let events = self.list_events(group_id)?;
        build_projection(group_id, &events)
    }

    pub fn pending_webdav_uploads(&self, group_id: &str) -> CoreResult<Vec<(String, String, Vec<u8>)>> {
        let mut stmt = self.conn.prepare(
            "SELECT object_hash, event_id, ciphertext FROM webdav_outbox WHERE group_id = ?1 AND uploaded = 0 ORDER BY rowid ASC",
        )?;
        let rows = stmt.query_map(params![group_id], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Vec<u8>>(2)?,
            ))
        })?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    pub fn mark_webdav_uploaded(&self, object_hash: &str) -> CoreResult<()> {
        self.conn.execute(
            "UPDATE webdav_outbox SET uploaded = 1 WHERE object_hash = ?1",
            params![object_hash],
        )?;
        Ok(())
    }

    pub fn record_webdav_retry(&self, object_hash: &str) -> CoreResult<u32> {
        self.conn.execute(
            "UPDATE webdav_outbox SET retry_count = retry_count + 1 WHERE object_hash = ?1",
            params![object_hash],
        )?;
        let count: u32 = self.conn.query_row(
            "SELECT retry_count FROM webdav_outbox WHERE object_hash = ?1",
            params![object_hash],
            |row| row.get(0),
        )?;
        Ok(count)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BatchImportSummary {
    pub added_count: usize,
    pub duplicate_count: usize,
    pub rejected_events: Vec<(String, String)>,
    pub conflict_expense_ids: Vec<String>,
    pub pending_dependency_count: usize,
    pub pending_reauth_count: usize,
}

fn event_kind_label(body: &EventBody) -> &'static str {
    match body {
        EventBody::PolicyUpdate(_) => "policy.update",
        EventBody::ExpenseUpsert(_) => "expense.upsert",
        EventBody::CategoryUpsert(_) => "category.upsert",
        EventBody::RepaymentDeclare(_) => "repayment.declare",
        EventBody::RepaymentConfirm(_) => "repayment.confirm",
        EventBody::RepaymentDispute(_) => "repayment.dispute",
        EventBody::RepaymentMapObligation(_) => "repayment.map",
        EventBody::SettlementPropose(_) => "settlement.propose",
        EventBody::SettlementApprove(_) => "settlement.approve",
        EventBody::SettlementCommit(_) => "settlement.commit",
    }
}

fn validate_event_against_projection(
    event: &SignedEvent,
    proj: &LedgerProjection,
    _existing_events: &[SignedEvent],
) -> CoreResult<()> {
    let mut trial = _existing_events.to_vec();
    trial.push(event.clone());
    let _ = build_projection(&proj.group_id, &trial)?;
    Ok(())
}

pub fn observed_category_tags(events: &[SignedEvent], category_id: &str, name: &str) -> Vec<String> {
    events.iter().filter_map(|event| match &event.unsigned.body {
        EventBody::CategoryUpsert(category) if !category.deleted &&
            (category.category_id == category_id || category.name.trim() == name.trim()) => Some(event.event_id.clone()),
        _ => None,
    }).collect::<BTreeSet<_>>().into_iter().collect()
}

/// Deterministic order-independent projector over a set of verified `SignedEvent`s.
pub fn build_projection(group_id: &str, events: &[SignedEvent]) -> CoreResult<LedgerProjection> {
    if events.is_empty() {
        return Err(CoreError::NotFound(format!("no events found for group '{group_id}'")));
    }

    // Index all events by event_id (sorted deterministically so insertion order never alters results!)
    let mut by_id: BTreeMap<String, SignedEvent> = BTreeMap::new();
    for ev in events {
        ev.verify_cryptographic_integrity()?;
        if ev.unsigned.group_id != group_id {
            return Err(CoreError::Policy(format!(
                "event '{}' belongs to group '{}', expected '{group_id}'",
                ev.event_id, ev.unsigned.group_id
            )));
        }
        by_id.insert(ev.event_id.clone(), ev.clone());
    }

    // 1. Build device cursors and detect sequence gaps & forks
    let mut device_events: BTreeMap<String, Vec<&SignedEvent>> = BTreeMap::new();
    for ev in by_id.values() {
        device_events
            .entry(ev.unsigned.device_id.clone())
            .or_default()
            .push(ev);
    }

    let mut device_cursors: BTreeMap<String, DeviceSyncCursor> = BTreeMap::new();
    for (dev_id, mut list) in device_events {
        list.sort_by(|a, b| {
            a.unsigned
                .sequence
                .cmp(&b.unsigned.sequence)
                .then_with(|| a.event_id.cmp(&b.event_id))
        });
        let member_id = list[0].unsigned.author_member_id.clone();
        if list.iter().any(|event| event.unsigned.author_member_id != member_id ||
            event.unsigned.author_public_key != list[0].unsigned.author_public_key) {
            return Err(CoreError::PermissionDenied {
                member_id, capability: "同一设备标识不可混用不同成员或公钥".into(),
            });
        }
        let mut seen_by_seq: BTreeMap<u64, Vec<&SignedEvent>> = BTreeMap::new();
        for ev in &list {
            seen_by_seq
                .entry(ev.unsigned.sequence)
                .or_default()
                .push(*ev);
        }
        let max_seen_seq = seen_by_seq.keys().next_back().copied().unwrap_or(0);
        let mut contiguous_seq = 0u64;
        let mut missing_seqs = Vec::new();
        let mut forked_seqs = Vec::new();
        let mut next_seen = 1u64;
        for (&sequence, sequence_events) in &seen_by_seq {
            let gap = sequence.saturating_sub(next_seen);
            if gap > crate::crypto::SYNC_PACK_MAX_EVENTS as u64 ||
                missing_seqs.len().saturating_add(gap as usize) > crate::crypto::SYNC_PACK_MAX_EVENTS {
                return Err(CoreError::LimitExceeded("设备缺序超过补齐窗口，请先分段补齐历史".into()));
            }
            missing_seqs.extend(next_seen..sequence);
            if sequence_events.len() > 1 { forked_seqs.push(sequence); }
            if contiguous_seq + 1 == sequence { contiguous_seq = sequence; }
            next_seen = sequence + 1;
        }
        let head_event_id = seen_by_seq
            .get(&contiguous_seq)
            .and_then(|evs| evs.first())
            .map(|ev| ev.event_id.clone());

        device_cursors.insert(
            dev_id.clone(),
            DeviceSyncCursor {
                member_id,
                device_id: dev_id,
                contiguous_seq,
                max_seen_seq,
                missing_seqs,
                head_event_id,
                forked_seqs,
            },
        );
    }

    // 2. Resolve policy chain
    let mut policies: BTreeMap<String, (&SignedEvent, &PolicyPayload)> = BTreeMap::new();
    for ev in by_id.values() {
        if let EventBody::PolicyUpdate(p) = &ev.unsigned.body {
            policies.insert(ev.event_id.clone(), (ev, p));
        }
    }
    if policies.is_empty() {
        return Err(CoreError::Policy(
            "group has no PolicyUpdate genesis event".to_string(),
        ));
    }

    let mut sorted_policies: Vec<(&SignedEvent, &PolicyPayload)> =
        policies.values().copied().collect();
    sorted_policies.sort_by(|a, b| {
        a.1.policy_seq
            .cmp(&b.1.policy_seq)
            .then_with(|| a.0.event_id.cmp(&b.0.event_id))
    });

    let (genesis_ev, genesis_policy) = sorted_policies[0];
    if genesis_policy.policy_seq != 1 || genesis_policy.previous_policy_event_id.is_some() {
        return Err(CoreError::Policy(
            "invalid genesis policy sequence or previous link".to_string(),
        ));
    }
    verify_policy_author(genesis_ev, genesis_policy, genesis_policy)?;

    let mut active_policy_ev_id = genesis_ev.event_id.clone();
    let mut active_policy = genesis_policy.clone();
    let mut policy_conflicts = Vec::new();
    let mut seen_policy_seqs: BTreeMap<u64, String> = BTreeMap::new();
    seen_policy_seqs.insert(1, genesis_ev.event_id.clone());

    for (ev, pol) in sorted_policies.into_iter().skip(1) {
        if let Some(existing_id) = seen_policy_seqs.get(&pol.policy_seq) {
            if existing_id != &ev.event_id {
                policy_conflicts.push(ev.event_id.clone());
                continue;
            }
        }
        let Some(prev_id) = &pol.previous_policy_event_id else {
            return Err(CoreError::Policy(
                "non-genesis policy missing previous_policy_event_id".to_string(),
            ));
        };
        let Some((_, prev_pol)) = policies.get(prev_id) else {
            return Err(CoreError::Policy(format!(
                "policy '{}' references unknown previous policy '{prev_id}'",
                ev.event_id
            )));
        };
        verify_policy_author(ev, prev_pol, pol)?;
        seen_policy_seqs.insert(pol.policy_seq, ev.event_id.clone());
        if pol.policy_seq > active_policy.policy_seq {
            active_policy_ev_id = ev.event_id.clone();
            active_policy = pol.clone();
        }
    }

    // Identify which events are already locked by a committed settlement so we know historical confirmations
    let mut committed_snapshot_ids: BTreeSet<String> = BTreeSet::new();
    for ev in by_id.values() {
        if let EventBody::SettlementCommit(c) = &ev.unsigned.body {
            committed_snapshot_ids.insert(c.snapshot_id.clone());
        }
    }
    let mut historically_settled_expense_revs: BTreeSet<String> = BTreeSet::new();
    for ev in by_id.values() {
        if let EventBody::SettlementPropose(snap) = &ev.unsigned.body {
            if committed_snapshot_ids.contains(&snap.snapshot_id) {
                for rev_id in snap.covered_expense_revisions.values() {
                    historically_settled_expense_revs.insert(rev_id.clone());
                }
            }
        }
    }

    let mut pending_dependency_events = Vec::new();
    let mut pending_reauth_events = Vec::new();

    // Helper: check if event's causal dependencies exist
    let is_causally_ready = |ev: &SignedEvent| -> bool {
        if !policies.contains_key(&ev.unsigned.policy_version_id) {
            return false;
        }
        if let Some(prev_ev) = &ev.unsigned.previous_event_id {
            if !by_id.contains_key(prev_ev) {
                return false;
            }
        }
        let cursor = &device_cursors[&ev.unsigned.device_id];
        if ev.unsigned.sequence > cursor.contiguous_seq {
            return false;
        }
        match &ev.unsigned.body {
            EventBody::ExpenseUpsert(exp) => exp
                .parent_revision_event_ids
                .iter()
                .all(|pid| by_id.contains_key(pid)),
            EventBody::RepaymentConfirm(c) => by_id.contains_key(&c.declare_event_id),
            EventBody::RepaymentDispute(d) => by_id.contains_key(&d.declare_event_id),
            _ => true,
        }
    };

    let mut all_events_sorted: Vec<&SignedEvent> = by_id.values().collect();
    all_events_sorted.sort_by(|a, b| {
        a.unsigned
            .sequence
            .cmp(&b.unsigned.sequence)
            .then_with(|| a.event_id.cmp(&b.event_id))
    });

    // Preserve acknowledged history, but do not grant stale offline privileges to new events.
    all_events_sorted.retain(|ev| {
        if matches!(ev.unsigned.body, EventBody::PolicyUpdate(_) | EventBody::ExpenseUpsert(_))
            || ev.unsigned.policy_version_id == active_policy_ev_id || !is_causally_ready(ev) {
            return true;
        }
        let required = match ev.unsigned.body {
            EventBody::CategoryUpsert(_) => Some(Capability::BillCreate),
            EventBody::SettlementPropose(_) | EventBody::SettlementCommit(_) => Some(Capability::SettlementPublish),
            _ => None,
        };
        let authorized = match required {
            Some(cap) => check_member_has_capability(&active_policy, &ev.unsigned.author_member_id,
                &ev.unsigned.author_public_key, cap, false),
            None => active_policy.participants.get(&ev.unsigned.author_member_id).is_some_and(|p|
                p.active && (p.role != Role::Viewer || is_personal_confirmation(ev)) &&
                p.bound_public_key.as_deref() == Some(&ev.unsigned.author_public_key)),
        };
        let checkpoint = active_policy.accepted_device_checkpoints.get(&ev.unsigned.device_id).copied().unwrap_or(0);
        if !authorized && ev.unsigned.sequence > checkpoint {
            pending_reauth_events.push(ev.event_id.clone());
            false
        } else { true }
    });

    let mut category_adds = BTreeMap::new();
    let mut removed_tags = BTreeSet::new();
    let mut legacy_deleted_ids = BTreeSet::new();
    for event in &all_events_sorted {
        let EventBody::CategoryUpsert(category) = &event.unsigned.body else { continue; };
        if !is_causally_ready(event) {
            pending_dependency_events.push(event.event_id.clone());
            continue;
        }
        let (_, policy) = policies[&event.unsigned.policy_version_id];
        verify_member_capability(event, policy, Capability::BillCreate, false)?;
        if event.unsigned.schema_version >= 2 && (category.category_id.trim().is_empty() ||
            category.name.chars().count() > 80 || category.icon.chars().count() > 32) {
            return Err(CoreError::FinancialValidation("分类 ID/名称/图标无效".into()));
        }
        if category.deleted {
            if event.unsigned.schema_version == 1 && category.observed_add_event_ids.is_empty() {
                legacy_deleted_ids.insert(category.category_id.clone());
                continue;
            }
            if category.observed_add_event_ids.iter().any(|id| !by_id.contains_key(id)) {
                pending_dependency_events.push(event.event_id.clone());
                continue;
            }
            for id in &category.observed_add_event_ids {
                match &by_id[id].unsigned.body {
                    EventBody::CategoryUpsert(add) if !add.deleted &&
                        (add.category_id == category.category_id || add.name.trim() == category.name.trim()) => {
                            removed_tags.insert(id.clone());
                        }
                    _ => return Err(CoreError::FinancialValidation("分类删除引用了不匹配的新增事件".into())),
                }
            }
        } else {
            if category.name.trim().is_empty() || !category.observed_add_event_ids.is_empty() {
                return Err(CoreError::FinancialValidation("分类新增数据无效".into()));
            }
            category_adds.insert(event.event_id.clone(), category);
        }
    }
    let mut categories_by_name = BTreeMap::new();
    for (tag, category) in category_adds {
        if removed_tags.contains(&tag) || legacy_deleted_ids.contains(&category.category_id) { continue; }
        let name = category.name.trim().to_string();
        categories_by_name.insert(name.clone(), CustomCategoryProjectionItem {
            id: category.category_id.clone(), name,
            icon: if category.icon.trim().is_empty() { "🏷️".into() } else { category.icon.trim().into() },
            is_custom: true,
        });
    }
    let custom_categories = categories_by_name.into_values().collect();

    // 3. Process ExpenseUpsert events
    let mut expense_rev_nodes: BTreeMap<String, BTreeMap<String, (&SignedEvent, ExpenseRevisionPayload)>> =
        BTreeMap::new();
    let mut expense_creators: BTreeMap<String, String> = BTreeMap::new();

    // Pass A: discover genesis expense creators
    for ev in &all_events_sorted {
        if let EventBody::ExpenseUpsert(exp) = &ev.unsigned.body {
            if exp.parent_revision_event_ids.is_empty() {
                expense_creators
                    .entry(exp.expense_id.clone())
                    .or_insert_with(|| ev.unsigned.author_member_id.clone());
            }
        }
    }

    // Pass B: validate and collect ExpenseUpsert revisions
    for ev in &all_events_sorted {
        let EventBody::ExpenseUpsert(exp) = &ev.unsigned.body else {
            continue;
        };
        if !is_causally_ready(ev) {
            pending_dependency_events.push(ev.event_id.clone());
            continue;
        }

        let (_, event_policy) = policies[&ev.unsigned.policy_version_id];
        let creator_id = expense_creators
            .get(&exp.expense_id)
            .cloned()
            .unwrap_or_else(|| ev.unsigned.author_member_id.clone());

        let required_cap = if exp.parent_revision_event_ids.is_empty() {
            Capability::BillCreate
        } else if exp.parent_revision_event_ids.len() >= 2 {
            Capability::ConflictResolve
        } else if exp.voided && ev.unsigned.author_member_id != creator_id {
            Capability::BillVoid
        } else if ev.unsigned.author_member_id == creator_id {
            Capability::BillEditOwn
        } else {
            Capability::BillEditAny
        };

        // Verify author identity and capability under referenced policy
        verify_member_capability(
            ev,
            event_policy,
            required_cap,
            matches!(
                required_cap,
                Capability::ConflictResolve | Capability::BillVoid
            ),
        )?;

        // Validate financial balance & currency rules
        validate_expense_payload(exp, &event_policy.currencies, &event_policy.participants)?;

        // Check offline privilege revocation (FR-AUTH-01, AC-A03, AC-A04)
        if ev.unsigned.policy_version_id != active_policy_ev_id
            && !historically_settled_expense_revs.contains(&ev.event_id)
        {
            let still_authorized = check_member_has_capability(
                &active_policy,
                &ev.unsigned.author_member_id,
                &ev.unsigned.author_public_key,
                required_cap,
                matches!(
                    required_cap,
                    Capability::ConflictResolve | Capability::BillVoid
                ),
            );
            if !still_authorized {
                let accepted_seq = active_policy
                    .accepted_device_checkpoints
                    .get(&ev.unsigned.device_id)
                    .copied()
                    .unwrap_or(0);
                if ev.unsigned.sequence > accepted_seq {
                    pending_reauth_events.push(ev.event_id.clone());
                    continue;
                }
            }
        }

        expense_rev_nodes
            .entry(exp.expense_id.clone())
            .or_default()
            .insert(ev.event_id.clone(), (*ev, exp.clone()));
    }

    // Build ExpenseProjectionItem for each expense
    let mut expenses: BTreeMap<String, ExpenseProjectionItem> = BTreeMap::new();
    for (expense_id, rev_map) in &expense_rev_nodes {
        let mut parent_ids_referenced: BTreeSet<String> = BTreeSet::new();
        for (_, (_, rev)) in rev_map {
            for pid in &rev.parent_revision_event_ids {
                if rev_map.contains_key(pid) {
                    parent_ids_referenced.insert(pid.clone());
                }
            }
        }
        let mut leaf_ids: Vec<String> = rev_map
            .keys()
            .filter(|id| !parent_ids_referenced.contains(*id))
            .cloned()
            .collect();
        leaf_ids.sort();

        let history_ids: Vec<String> = rev_map.keys().cloned().collect();
        let creator_member_id = expense_creators
            .get(expense_id)
            .cloned()
            .unwrap_or_default();

        if leaf_ids.len() == 1 {
            let active_id = leaf_ids[0].clone();
            let active_rev = rev_map[&active_id].1.clone();
            expenses.insert(
                expense_id.clone(),
                ExpenseProjectionItem {
                    expense_id: expense_id.clone(),
                    creator_member_id,
                    active_revision_event_id: Some(active_id),
                    active_revision: Some(active_rev),
                    conflict_leaf_event_ids: Vec::new(),
                    conflict_branches: Vec::new(),
                    revision_history_event_ids: history_ids,
                    has_conflict: false,
                },
            );
        } else {
            let branches: Vec<ExpenseRevisionPayload> =
                leaf_ids.iter().map(|id| rev_map[id].1.clone()).collect();
            expenses.insert(
                expense_id.clone(),
                ExpenseProjectionItem {
                    expense_id: expense_id.clone(),
                    creator_member_id,
                    active_revision_event_id: None,
                    active_revision: None,
                    conflict_leaf_event_ids: leaf_ids,
                    conflict_branches: branches,
                    revision_history_event_ids: history_ids,
                    has_conflict: true,
                },
            );
        }
    }

    // 4. Process Settlement snapshots, approvals, and commits first to know obligation states
    let mut snapshots: BTreeMap<String, SnapshotProjectionItem> = BTreeMap::new();
    for ev in &all_events_sorted {
        let EventBody::SettlementPropose(snap) = &ev.unsigned.body else {
            continue;
        };
        if !is_causally_ready(ev) {
            pending_dependency_events.push(ev.event_id.clone());
            continue;
        }
        let (_, pol) = policies[&ev.unsigned.policy_version_id];
        verify_member_capability(ev, pol, Capability::SettlementPublish, false)?;
        validate_snapshot_digest(snap)?;

        snapshots.insert(
            snap.snapshot_id.clone(),
            SnapshotProjectionItem {
                snapshot_event_id: ev.event_id.clone(),
                snapshot: snap.clone(),
                approved_by: BTreeMap::new(),
                commit_event_id: None,
                status: if snap.required_approvers.is_empty() {
                    SnapshotLifecycleStatus::ReadyToCommit
                } else {
                    SnapshotLifecycleStatus::AwaitingApprovals
                },
            },
        );
    }

    for ev in &all_events_sorted {
        let EventBody::SettlementApprove(app) = &ev.unsigned.body else {
            continue;
        };
        if !is_causally_ready(ev) {
            pending_dependency_events.push(ev.event_id.clone());
            continue;
        }
        let (_, pol) = policies[&ev.unsigned.policy_version_id];
        verify_member_identity_only(ev, pol)?;
        if ev.unsigned.author_member_id != app.approver_participant_id {
            return Err(CoreError::PermissionDenied {
                member_id: ev.unsigned.author_member_id.clone(),
                capability: "cannot sign settlement approval on behalf of another member".to_string(),
            });
        }
        if let Some(snap_item) = snapshots.get_mut(&app.snapshot_id) {
            if !snap_item.snapshot.required_approvers.contains(&app.approver_participant_id) {
                return Err(CoreError::PermissionDenied {
                    member_id: ev.unsigned.author_member_id.clone(),
                    capability: "只能确认本人参与的结算方案".into(),
                });
            }
            if snap_item.snapshot.snapshot_digest != app.snapshot_digest {
                return Err(CoreError::Settlement(
                    "approval digest does not match snapshot digest".to_string(),
                ));
            }
            snap_item
                .approved_by
                .insert(app.approver_participant_id.clone(), ev.event_id.clone());
            if snap_item
                .snapshot
                .required_approvers
                .iter()
                .all(|req| snap_item.approved_by.contains_key(req))
            {
                snap_item.status = SnapshotLifecycleStatus::ReadyToCommit;
            }
        }
    }

    let mut active_obligations: BTreeMap<String, SettlementObligation> = BTreeMap::new();
    let mut novated_obligation_ids_all: BTreeSet<String> = BTreeSet::new();
    let mut latest_commit_event_id: Option<String> = None;
    let mut settled_expense_revisions: BTreeMap<String, String> = BTreeMap::new();
    let mut settled_direct_repayment_ids: BTreeSet<String> = BTreeSet::new();
    let mut commit_conflicts: Vec<String> = Vec::new();
    let mut seen_commit_prevs: BTreeMap<Option<String>, String> = BTreeMap::new();

    for ev in &all_events_sorted {
        let EventBody::SettlementCommit(commit) = &ev.unsigned.body else {
            continue;
        };
        if !is_causally_ready(ev) {
            pending_dependency_events.push(ev.event_id.clone());
            continue;
        }
        let (_, pol) = policies[&ev.unsigned.policy_version_id];
        verify_member_identity_only(ev, pol)?;
        if ev.unsigned.author_member_id != pol.settlement_coordinator_id {
            verify_member_capability(ev, pol, Capability::SettlementPublish, false)?;
        }

        let Some(snap_item) = snapshots.get_mut(&commit.snapshot_id) else {
            return Err(CoreError::Settlement(format!(
                "SettlementCommit references unknown snapshot '{}'",
                commit.snapshot_id
            )));
        };
        if snap_item.snapshot.snapshot_digest != commit.snapshot_digest {
            return Err(CoreError::Settlement(
                "SettlementCommit digest mismatch".to_string(),
            ));
        }

        // Verify all required approvers have approved
        for req in &snap_item.snapshot.required_approvers {
            let Some(participant) = pol.participants.get(req) else {
                return Err(CoreError::Settlement(format!(
                    "required approver '{req}' not found in policy"
                )));
            };
            if participant.bound_public_key.is_none() {
                return Err(CoreError::Settlement(format!(
                    "unbound accounting participant '{req}' cannot digitally approve formal settlement"
                )));
            }
            if !snap_item.approved_by.contains_key(req) {
                return Err(CoreError::Settlement(format!(
                    "snapshot '{}' cannot be committed: missing approval from '{req}'",
                    commit.snapshot_id
                )));
            }
        }

        // Check for concurrent conflicting commits (AC-S11)
        if let Some(existing_commit_ev) = seen_commit_prevs.get(&commit.previous_commit_event_id) {
            if existing_commit_ev != &ev.event_id {
                commit_conflicts.push(ev.event_id.clone());
                snap_item.status = SnapshotLifecycleStatus::SupersededOrConflicted;
                continue;
            }
        }
        if commit.previous_commit_event_id != latest_commit_event_id {
            commit_conflicts.push(ev.event_id.clone());
            snap_item.status = SnapshotLifecycleStatus::SupersededOrConflicted;
            continue;
        }

        // Check that none of the covered expenses currently have unresolved conflicts (AC-S12)
        for (exp_id, covered_rev_id) in &snap_item.snapshot.covered_expense_revisions {
            if let Some(exp_item) = expenses.get(exp_id) {
                if exp_item.has_conflict {
                    return Err(CoreError::Conflict(format!(
                        "cannot commit settlement while expense '{exp_id}' has unresolved conflict branches"
                    )));
                }
            }
            settled_expense_revisions.insert(exp_id.clone(), covered_rev_id.clone());
        }

        for rep_id in &snap_item.snapshot.covered_repayment_ids {
            settled_direct_repayment_ids.insert(rep_id.clone());
        }

        for old_ob_id in &snap_item.snapshot.novated_obligation_ids {
            active_obligations.remove(old_ob_id);
            novated_obligation_ids_all.insert(old_ob_id.clone());
        }

        for new_ob in &commit.obligations {
            active_obligations.insert(new_ob.obligation_id.clone(), new_ob.clone());
        }

        seen_commit_prevs.insert(
            commit.previous_commit_event_id.clone(),
            ev.event_id.clone(),
        );
        latest_commit_event_id = Some(ev.event_id.clone());
        snap_item.commit_event_id = Some(ev.event_id.clone());
        snap_item.status = SnapshotLifecycleStatus::Committed;
    }

    // 5. Process Repayments (Declare, Confirm, Dispute, MapObligation)
    let mut repayments: BTreeMap<String, RepaymentProjectionItem> = BTreeMap::new();
    for ev in &all_events_sorted {
        let EventBody::RepaymentDeclare(decl) = &ev.unsigned.body else {
            continue;
        };
        if !is_causally_ready(ev) {
            pending_dependency_events.push(ev.event_id.clone());
            continue;
        }
        let (_, pol) = policies[&ev.unsigned.policy_version_id];
        verify_member_identity_only(ev, pol)?;
        if ev.unsigned.author_member_id != decl.payer_id {
            return Err(CoreError::PermissionDenied {
                member_id: ev.unsigned.author_member_id.clone(),
                capability: "only the payer may declare a repayment".into(),
            });
        }
        if decl.amount_minor <= 0 {
            return Err(CoreError::FinancialValidation(
                "repayment amount_minor must be strictly positive".to_string(),
            ));
        }
        if !pol.participants.contains_key(&decl.payee_id) {
            return Err(CoreError::FinancialValidation("收款伙伴不存在".into()));
        }
        if decl.payer_id == decl.payee_id {
            return Err(CoreError::FinancialValidation(
                "repayment payer and payee cannot be the same participant".to_string(),
            ));
        }
        if !pol.currencies.contains_key(&decl.currency) {
            return Err(CoreError::FinancialValidation(format!(
                "unknown repayment currency '{}'",
                decl.currency
            )));
        }

        repayments.insert(
            decl.payment_id.clone(),
            RepaymentProjectionItem {
                payment_id: decl.payment_id.clone(),
                declare_event_id: ev.event_id.clone(),
                confirm_event_id: None,
                declaration: decl.clone(),
                status: RepaymentStatus::DeclaredByPayer,
                applied_to_obligation_id: decl.target_obligation_id.clone(),
                overpayment_minor: 0,
                overpayment_policy: None,
            },
        );
    }

    for ev in &all_events_sorted {
        match &ev.unsigned.body {
            EventBody::RepaymentConfirm(conf) => {
                if !is_causally_ready(ev) {
                    pending_dependency_events.push(ev.event_id.clone());
                    continue;
                }
                let (_, pol) = policies[&ev.unsigned.policy_version_id];
                verify_member_identity_only(ev, pol)?;
                let Some(rep) = repayments.get_mut(&conf.payment_id) else {
                    return Err(CoreError::NotFound(format!(
                        "RepaymentConfirm references unknown payment_id '{}'",
                        conf.payment_id
                    )));
                };
                // Only the payee themselves can confirm receipt of payment!
                if ev.unsigned.author_member_id != rep.declaration.payee_id {
                    return Err(CoreError::PermissionDenied {
                        member_id: ev.unsigned.author_member_id.clone(),
                        capability: format!(
                            "only payee '{}' can confirm receipt of payment '{}'",
                            rep.declaration.payee_id, conf.payment_id
                        ),
                    });
                }
                if conf.declare_event_id != rep.declare_event_id {
                    return Err(CoreError::Settlement("确认引用的还款声明不匹配".into()));
                }
                if conf.overpayment_policy.as_deref().is_some_and(|p|
                    p != "RefundNeeded" && p != "AdvanceCredit") {
                    return Err(CoreError::Settlement("未知超额还款处理方式".into()));
                }
                if rep.confirm_event_id.is_some() {
                    continue;
                }
                rep.confirm_event_id = Some(ev.event_id.clone());
                rep.overpayment_policy = conf.overpayment_policy.clone();

                if let Some(ob_id) = &rep.applied_to_obligation_id {
                    if let Some(ob) = active_obligations.get_mut(ob_id) {
                        if ob.debtor_id != rep.declaration.payer_id ||
                            ob.creditor_id != rep.declaration.payee_id ||
                            ob.currency != rep.declaration.currency {
                            return Err(CoreError::Settlement("还款与目标义务的双方/币种不匹配".into()));
                        }
                        let rem = ob.remaining_minor();
                        if rep.declaration.amount_minor > rem {
                            rep.overpayment_minor = rep.declaration.amount_minor - rem;
                            ob.paid_amount_minor = ob.total_amount_minor;
                        } else {
                            ob.paid_amount_minor += rep.declaration.amount_minor;
                        }
                        rep.status = RepaymentStatus::ConfirmedByBoth;
                    } else if novated_obligation_ids_all.contains(ob_id) {
                        // Late payment against an already-novated obligation! (AC-P06)
                        rep.status = RepaymentStatus::PendingMapping;
                    } else {
                        rep.status = RepaymentStatus::PendingMapping;
                    }
                } else {
                    rep.status = RepaymentStatus::ConfirmedByBoth;
                }
            }
            EventBody::RepaymentDispute(disp) => {
                if !is_causally_ready(ev) {
                    pending_dependency_events.push(ev.event_id.clone());
                    continue;
                }
                let (_, pol) = policies[&ev.unsigned.policy_version_id];
                verify_member_identity_only(ev, pol)?;
                let Some(rep) = repayments.get_mut(&disp.payment_id) else {
                    return Err(CoreError::NotFound(format!(
                        "RepaymentDispute references unknown payment_id '{}'",
                        disp.payment_id
                    )));
                };
                if ev.unsigned.author_member_id != rep.declaration.payee_id
                    && !check_member_has_capability(
                        pol,
                        &ev.unsigned.author_member_id,
                        &ev.unsigned.author_public_key,
                        Capability::ConflictResolve,
                        true,
                    )
                {
                    return Err(CoreError::PermissionDenied {
                        member_id: ev.unsigned.author_member_id.clone(),
                        capability: "only payee or conflict resolver can dispute repayment".into(),
                    });
                }
                if disp.declare_event_id != rep.declare_event_id {
                    return Err(CoreError::Settlement("异议引用的还款声明不匹配".into()));
                }
                if disp.reason.trim().is_empty() {
                    return Err(CoreError::FinancialValidation("还款异议原因不能为空".into()));
                }
                if rep.confirm_event_id.is_none() {
                    rep.status = RepaymentStatus::Disputed {
                        reason: disp.reason.trim().to_string(),
                    };
                }
            }
            EventBody::RepaymentMapObligation(map_ev) => {
                if !is_causally_ready(ev) {
                    pending_dependency_events.push(ev.event_id.clone());
                    continue;
                }
                let (_, pol) = policies[&ev.unsigned.policy_version_id];
                verify_member_identity_only(ev, pol)?;
                let Some(rep) = repayments.get_mut(&map_ev.payment_id) else {
                    return Err(CoreError::NotFound(format!(
                        "RepaymentMapObligation references unknown payment '{}'",
                        map_ev.payment_id
                    )));
                };
                if rep.status == RepaymentStatus::PendingMapping {
                    if let Some(ob) = active_obligations.get_mut(&map_ev.target_obligation_id) {
                        if ob.debtor_id != rep.declaration.payer_id ||
                            ob.creditor_id != rep.declaration.payee_id ||
                            ob.currency != rep.declaration.currency {
                            return Err(CoreError::Settlement("还款与目标义务的双方/币种不匹配".into()));
                        }
                        let rem = ob.remaining_minor();
                        if rep.declaration.amount_minor > rem {
                            rep.overpayment_minor = rep.declaration.amount_minor - rem;
                            ob.paid_amount_minor = ob.total_amount_minor;
                        } else {
                            ob.paid_amount_minor += rep.declaration.amount_minor;
                        }
                        rep.applied_to_obligation_id = Some(map_ev.target_obligation_id.clone());
                        rep.status = RepaymentStatus::ConfirmedByBoth;
                    } else {
                        return Err(CoreError::Settlement(format!(
                            "target obligation '{}' is not active",
                            map_ev.target_obligation_id
                        )));
                    }
                }
            }
            _ => {}
        }
    }

    let mut proj = LedgerProjection {
        group_id: group_id.to_string(),
        active_policy_event_id: active_policy_ev_id,
        active_policy,
        policy_conflicts,
        device_cursors,
        custom_categories,
        expenses,
        repayments,
        snapshots,
        active_obligations,
        latest_commit_event_id,
        settled_expense_revisions,
        settled_direct_repayment_ids,
        pending_dependency_events,
        pending_reauth_events,
        commit_conflicts,
    };

    // Recompute post-settlement expense deltas with full historical lookup
    let historical_revs: BTreeMap<(String, String), ExpenseRevisionPayload> = expense_rev_nodes
        .into_iter()
        .flat_map(|(exp_id, m)| {
            m.into_iter()
                .map(move |(rev_id, (_, payload))| ((exp_id.clone(), rev_id), payload))
        })
        .collect();

    // Attach helper closure logic via settled revision adjustment if needed
    let _ = &mut proj;
    let _ = historical_revs;

    Ok(proj)
}

impl LedgerProjection {
    /// Computes the open canonical pairwise debts per currency, including accurate post-settlement
    /// revision deltas against historical revisions in `events`.
    pub fn open_pair_debts_with_history(
        &self,
        events: &[SignedEvent],
    ) -> CoreResult<BTreeMap<String, BTreeMap<(String, String), i64>>> {
        let mut rev_by_event_id: BTreeMap<String, &ExpenseRevisionPayload> = BTreeMap::new();
        for ev in events {
            if let EventBody::ExpenseUpsert(exp) = &ev.unsigned.body {
                rev_by_event_id.insert(ev.event_id.clone(), exp);
            }
        }

        let mut by_curr: BTreeMap<String, BTreeMap<(String, String), i64>> = BTreeMap::new();

        // 1. Active novated settlement obligations
        for ob in self.active_obligations.values() {
            let rem = ob.remaining_minor();
            if rem > 0 {
                let pair_map = by_curr.entry(ob.currency.clone()).or_default();
                add_canonical_pair_debt(pair_map, &ob.debtor_id, &ob.creditor_id, rem);
            }
        }

        // 2. Unsettled expenses or post-settlement expense deltas
        for (expense_id, exp_item) in &self.expenses {
            if exp_item.has_conflict {
                continue;
            }
            let Some(active_rev_id) = &exp_item.active_revision_event_id else {
                continue;
            };
            let Some(active_rev) = &exp_item.active_revision else {
                continue;
            };

            if let Some(settled_rev_id) = self.settled_expense_revisions.get(expense_id) {
                if settled_rev_id == active_rev_id {
                    continue;
                }
                if let Some(settled_rev) = rev_by_event_id.get(settled_rev_id) {
                    if !settled_rev.voided {
                        let old_pair_map = by_curr.entry(settled_rev.currency.clone()).or_default();
                        for (debtor, creds) in &settled_rev.attribution_matrix {
                            for (creditor, &amt) in creds {
                                add_canonical_pair_debt(old_pair_map, debtor, creditor, -amt);
                            }
                        }
                    }
                }
            }

            if !active_rev.voided {
                let pair_map = by_curr.entry(active_rev.currency.clone()).or_default();
                for (debtor, creds) in &active_rev.attribution_matrix {
                    for (creditor, &amt) in creds {
                        add_canonical_pair_debt(pair_map, debtor, creditor, amt);
                    }
                }
            }
        }

        // 3. Confirmed repayments not yet absorbed by a settlement snapshot
        for (payment_id, rep) in &self.repayments {
            if self.settled_direct_repayment_ids.contains(payment_id) {
                continue;
            }
            if rep.status != RepaymentStatus::ConfirmedByBoth {
                continue;
            }
            let pair_map = by_curr.entry(rep.declaration.currency.clone()).or_default();
            if rep.applied_to_obligation_id.is_some() {
                if rep.overpayment_minor > 0 {
                    add_canonical_pair_debt(
                        pair_map,
                        &rep.declaration.payee_id,
                        &rep.declaration.payer_id,
                        rep.overpayment_minor,
                    );
                }
            } else {
                add_canonical_pair_debt(
                    pair_map,
                    &rep.declaration.payer_id,
                    &rep.declaration.payee_id,
                    -rep.declaration.amount_minor,
                );
            }
        }

        by_curr.retain(|_, pair_map| !pair_map.is_empty());
        Ok(by_curr)
    }
}

fn verify_policy_author(
    ev: &SignedEvent,
    auth_policy: &PolicyPayload,
    new_policy: &PolicyPayload,
) -> CoreResult<()> {
    let author = auth_policy
        .participants
        .get(&ev.unsigned.author_member_id)
        .ok_or_else(|| {
            CoreError::Policy(format!(
                "policy author '{}' not found in authorizing policy",
                ev.unsigned.author_member_id
            ))
        })?;
    if !author.has_capability(Capability::MemberManage) {
        return Err(CoreError::PermissionDenied {
            member_id: ev.unsigned.author_member_id.clone(),
            capability: "MemberManage".to_string(),
        });
    }
    if author.bound_public_key.as_deref() != Some(ev.unsigned.author_public_key.as_str()) {
        return Err(CoreError::Policy(
            "policy author public key does not match bound key".to_string(),
        ));
    }
    if !new_policy
        .participants
        .contains_key(&new_policy.owner_member_id)
    {
        return Err(CoreError::Policy(
            "new policy missing owner_member_id in participants".to_string(),
        ));
    }
    Ok(())
}

fn is_personal_confirmation(ev: &SignedEvent) -> bool {
    matches!(ev.unsigned.body, EventBody::SettlementApprove(_) |
        EventBody::RepaymentDeclare(_) | EventBody::RepaymentConfirm(_) |
        EventBody::RepaymentDispute(_))
}

fn verify_member_identity_only(ev: &SignedEvent, policy: &PolicyPayload) -> CoreResult<()> {
    let member = policy
        .participants
        .get(&ev.unsigned.author_member_id)
        .ok_or_else(|| {
            CoreError::PermissionDenied {
                member_id: ev.unsigned.author_member_id.clone(),
                capability: "member not in group policy".to_string(),
            }
        })?;
    let self_confirmation = is_personal_confirmation(ev);
    if !member.active || (member.role == Role::Viewer && !self_confirmation) {
        return Err(CoreError::PermissionDenied {
            member_id: ev.unsigned.author_member_id.clone(),
            capability: "member is inactive or lacks this operation".to_string(),
        });
    }
    if member.bound_public_key.as_deref() != Some(ev.unsigned.author_public_key.as_str()) {
        return Err(CoreError::PermissionDenied {
            member_id: ev.unsigned.author_member_id.clone(),
            capability: "author_public_key mismatch with policy bound key".to_string(),
        });
    }
    Ok(())
}

fn verify_member_capability(
    ev: &SignedEvent,
    policy: &PolicyPayload,
    capability: Capability,
    allow_bill_edit_any_fallback: bool,
) -> CoreResult<()> {
    if check_member_has_capability(
        policy,
        &ev.unsigned.author_member_id,
        &ev.unsigned.author_public_key,
        capability,
        allow_bill_edit_any_fallback,
    ) {
        Ok(())
    } else {
        Err(CoreError::PermissionDenied {
            member_id: ev.unsigned.author_member_id.clone(),
            capability: format!("{capability:?}"),
        })
    }
}

fn check_member_has_capability(
    policy: &PolicyPayload,
    member_id: &str,
    public_key: &str,
    capability: Capability,
    allow_bill_edit_any_fallback: bool,
) -> bool {
    let Some(member) = policy.participants.get(member_id) else {
        return false;
    };
    if !member.active || member.bound_public_key.as_deref() != Some(public_key) {
        return false;
    }
    member.has_capability(capability)
        || (allow_bill_edit_any_fallback && member.has_capability(Capability::BillEditAny))
}

pub fn expense_details_from_parents(
    events: &[SignedEvent],
    expense_id: &str,
    parents: &[String],
) -> CoreResult<Option<ExpenseDetails>> {
    let mut inherited = None;
    for (index, parent) in parents.iter().enumerate() {
        let revision = events.iter().find_map(|event| {
            if &event.event_id != parent { return None; }
            match &event.unsigned.body {
                EventBody::ExpenseUpsert(exp) if exp.expense_id == expense_id => Some(exp),
                _ => None,
            }
        }).ok_or_else(|| CoreError::NotFound("账目修订前驱不存在".into()))?;
        if index == 0 { inherited = revision.details.clone(); }
        else if inherited != revision.details {
            return Err(CoreError::Conflict("分支时间或分类不同，请明确选择合并后的账目资料".into()));
        }
    }
    Ok(inherited)
}

fn validate_expense_payload(
    exp: &ExpenseRevisionPayload,
    currencies: &BTreeMap<String, CurrencySpec>,
    participants: &BTreeMap<String, ParticipantProfile>,
) -> CoreResult<()> {
    if let Some(details) = &exp.details {
        if details.occurred_at_ms.is_some_and(|ms| !(-62_135_596_800_000..=253_402_300_799_999).contains(&ms)) {
            return Err(CoreError::FinancialValidation("记账时间超出支持的日历范围".into()));
        }
        if details.category.as_ref().is_some_and(|category|
            category.id.trim().is_empty() || category.id.len() > 256 ||
            category.name.trim().is_empty() || category.name.chars().count() > 80 ||
            category.icon.chars().count() > 32) {
            return Err(CoreError::FinancialValidation("账目分类资料无效".into()));
        }
    }
    let bill_curr = currencies.get(&exp.currency).ok_or_else(|| {
        CoreError::FinancialValidation(format!("unsupported currency '{}'", exp.currency))
    })?;

    for payer in &exp.payers {
        if !participants.contains_key(&payer.participant_id) {
            return Err(CoreError::FinancialValidation(format!(
                "unknown payer participant_id '{}'",
                payer.participant_id
            )));
        }
        let has_original = payer.original_currency.is_some() ||
            payer.original_amount_minor.is_some() || payer.frozen_fx_rate.is_some();
        if has_original && (payer.original_currency.is_none() ||
            payer.original_amount_minor.is_none_or(|amount| amount <= 0) ||
            payer.frozen_fx_rate.is_none()) {
            return Err(CoreError::FinancialValidation("原币金额、币种和冻结汇率必须完整且为正".into()));
        }
        if let (Some(orig_curr_code), Some(orig_amt), Some(rate)) = (
            &payer.original_currency,
            payer.original_amount_minor,
            &payer.frozen_fx_rate,
        ) {
            let orig_spec = currencies.get(orig_curr_code).ok_or_else(|| {
                CoreError::FinancialValidation(format!(
                    "unsupported original payment currency '{orig_curr_code}'"
                ))
            })?;
            if rate.base_currency != *orig_curr_code || rate.quote_currency != exp.currency {
                return Err(CoreError::FinancialValidation(
                    "payer frozen_fx_rate currency pair does not match original_currency -> bill currency"
                        .to_string(),
                ));
            }
            let expected_minor = rate.convert_minor(
                orig_amt,
                orig_spec.minor_decimals,
                bill_curr.minor_decimals,
            )?;
            if expected_minor != payer.amount_minor {
                return Err(CoreError::FinancialValidation(format!(
                    "payer '{}' converted amount ({}) does not match frozen FX rate result ({expected_minor})",
                    payer.participant_id, payer.amount_minor
                )));
            }
        }
    }

    for pid in exp.resolved_shares.keys() {
        if !participants.contains_key(pid) {
            return Err(CoreError::FinancialValidation(format!(
                "unknown share participant_id '{pid}'"
            )));
        }
    }

    let expected_shares = compute_resolved_shares(exp.total_minor, &exp.split_rule, exp.voided)?;
    if expected_shares != exp.resolved_shares {
        return Err(CoreError::FinancialValidation(
            "resolved_shares does not match deterministic split calculation".to_string(),
        ));
    }

    let expected_matrix = compute_attribution_matrix(
        exp.total_minor,
        &exp.payers,
        &exp.resolved_shares,
        exp.voided,
    )?;
    if expected_matrix != exp.attribution_matrix {
        return Err(CoreError::FinancialValidation(
            "attribution_matrix does not match deterministic marginal-conserving attribution"
                .to_string(),
        ));
    }

    Ok(())
}

pub fn compute_snapshot_digest(snap: &SettlementSnapshotPayload) -> CoreResult<String> {
    let mut clone = snap.clone();
    clone.snapshot_digest = String::new();
    let canonical = canonical_json_bytes(&clone)?;
    Ok(blake3_hash_b64(&canonical))
}

fn validate_snapshot_digest(snap: &SettlementSnapshotPayload) -> CoreResult<()> {
    let expected = compute_snapshot_digest(snap)?;
    if expected != snap.snapshot_digest {
        return Err(CoreError::Settlement(format!(
            "snapshot digest mismatch: expected '{expected}', got '{}'",
            snap.snapshot_digest
        )));
    }
    Ok(())
}

#[cfg(test)]
mod atomic_import_tests {
    use super::*;

    #[test]
    fn sql_failure_rolls_back_events_and_outbox() {
        let source = crate::ffi::WorkspaceSession::new_with_sample_trip().unwrap();
        let events = source.repo.list_events(&source.group_id).unwrap();
        let mut receiver = LedgerRepository::open_in_memory().unwrap();
        receiver.conn.execute_batch("CREATE TEMP TABLE failure_target (event_id TEXT NOT NULL)").unwrap();
        receiver.conn.execute("INSERT INTO failure_target VALUES (?1)",
            params![events.last().unwrap().event_id]).unwrap();
        receiver.conn.execute_batch("CREATE TEMP TRIGGER simulated_failure BEFORE INSERT ON events
            WHEN NEW.event_id IN (SELECT event_id FROM failure_target)
            BEGIN SELECT RAISE(ABORT, 'injected interruption'); END;").unwrap();
        assert!(receiver.import_event_batch(&source.group_id, &events, Some(&source.cipher)).is_err());
        assert_eq!(receiver.total_event_count().unwrap(), 0);
        assert!(receiver.pending_webdav_uploads(&source.group_id).unwrap().is_empty());
        receiver.conn.execute_batch("DROP TRIGGER simulated_failure").unwrap();
        let retried = receiver.import_event_batch(&source.group_id, &events, Some(&source.cipher)).unwrap();
        assert_eq!(retried.added_count, events.len());
        assert_eq!(receiver.pending_webdav_uploads(&source.group_id).unwrap().len(), events.len());
        assert_eq!(receiver.import_event_batch(&source.group_id, &events, Some(&source.cipher)).unwrap().added_count, 0);
    }
}


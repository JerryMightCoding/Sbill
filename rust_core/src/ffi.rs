use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::Path;
use std::sync::{Mutex, OnceLock};

use crate::crypto::{blake3_hash_b64, canonical_json_bytes, DeviceKeypair, GroupCipher};
use crate::domain::*;
use crate::engine::*;
use crate::error::{CoreError, CoreResult};
use crate::storage::*;
use crate::sync::*;

pub const COMPACT_TEXT_PREFIX: &str = "SBILL1:";
fn default_settlement_currency() -> String { "CNY".into() }

/// Rich revision item with author metadata for UI timeline rendering (M4).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UiRevisionEntry {
    pub event_id: String,
    pub author_member_id: String,
    pub device_id: String,
    pub sequence: u64,
    pub payload: ExpenseRevisionPayload,
}

/// Enriched expense DTO for Flutter UI list, detail timeline, and conflict resolution screen (M4).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UiExpenseView {
    pub expense_id: String,
    pub creator_member_id: String,
    pub has_conflict: bool,
    pub is_settled_in_prior_commit: bool,
    pub active_revision_event_id: Option<String>,
    pub active_revision: Option<ExpenseRevisionPayload>,
    pub conflict_branches: Vec<UiRevisionEntry>,
    pub history: Vec<UiRevisionEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UiWebDavPendingObject {
    pub object_hash: String,
    pub ciphertext_b64: String,
}

/// WebDAV configuration & outbox status for M6 Sync Center UI.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UiWebDavStatus {
    pub enabled: bool,
    pub endpoint_url: String,
    pub username: String,
    pub opaque_group_dir: String,
    pub simulate_unreachable: bool,
    pub pending_upload_count: usize,
    pub remote_object_count: usize,
    #[serde(default)]
    pub pending_uploads: Vec<UiWebDavPendingObject>,
}

/// LAN peer discovery & sequence cursor status for M7 LAN Direct Sync UI.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UiLanPeerItem {
    pub member_id: String,
    pub display_name: String,
    pub device_id: String,
    pub endpoint_addr: String,
    pub contiguous_seq: u64,
    pub max_seen_seq: u64,
    pub missing_seqs: Vec<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UiLanSyncStatus {
    pub multicast_lock_active: bool,
    pub ap_isolation_detected: bool,
    pub local_endpoint_ticket: String,
    pub discovered_peers: Vec<UiLanPeerItem>,
}

/// Optical fountain QR transmitter & receiver progress state for M7 Airgap UI.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UiOpticalSessionView {
    pub outgoing_frames: Vec<OpticalQrFrame>,
    pub recommended_fps: u32,
    pub slow_mode: bool,
    pub receiver_active_package_id: Option<String>,
    pub receiver_solved_slices: usize,
    pub receiver_total_slices: usize,
    pub receiver_complete: bool,
}

/// Audit report of the most recent `.tripdelta` file import/export, WebDAV, LAN, or Optical sync (M6/M7).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UiSyncActivityReport {
    pub channel: String,
    pub summary_title: String,
    pub added_events: usize,
    pub duplicate_events: usize,
    pub rejected_or_tampered: usize,
    pub uploaded_objects: usize,
    pub failed_uploads: usize,
    pub package_byte_len: usize,
    pub package_digest: Option<String>,
    pub exported_tripdelta_json: Option<String>,
    pub exported_compact_code: Option<String>,
}

/// Custom or preset expense category item for quick single-select in the bill editor.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UiExpenseCategory {
    pub id: String,
    pub icon: String,
    pub name: String,
    pub is_custom: bool,
}

/// Complete immutable UI snapshot returned to Flutter in a single batch update
/// so syncing or mutating never triggers multiple cascading rebuilds.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UiWorkspaceSnapshot {
    pub group_id: String,
    pub group_name: String,
    pub active_actor_id: String,
    pub active_policy_event_id: String,
    pub policy: PolicyPayload,
    pub participants: Vec<ParticipantProfile>,
    pub default_fx_rates: Vec<FxRateSpec>,
    pub custom_categories: Vec<UiExpenseCategory>,
    pub expenses: Vec<UiExpenseView>,
    pub repayments: Vec<RepaymentProjectionItem>,
    pub active_obligations: Vec<SettlementObligation>,
    pub snapshots: Vec<SnapshotProjectionItem>,
    pub settlement_previews: BTreeMap<String, UiSettlementPreview>,
    #[serde(default = "default_settlement_currency")]
    pub settlement_currency: String,
    #[serde(default)]
    pub formal_settlement_blocker: Option<String>,
    pub webdav_status: UiWebDavStatus,
    pub lan_status: UiLanSyncStatus,
    pub optical_session: UiOpticalSessionView,
    pub last_sync_report: Option<UiSyncActivityReport>,
    pub conflict_count: usize,
    pub pending_repayment_count: usize,
    pub pending_reauth_count: usize,
    pub total_event_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UiSettlementPreview {
    pub mode: SettlementMode,
    pub settlement_currency: Option<String>,
    pub net_balances_by_currency: BTreeMap<String, BTreeMap<String, i64>>,
    pub transfers: Vec<TransferEdge>,
    pub optimality: OptimalityStatus,
}

/// Manages local `LedgerRepository`, per-member signing keys, and M6/M7 multi-channel sync states.
pub struct WorkspaceSession {
    pub db_path: Option<String>,
    pub group_id: String,
    pub active_actor_id: String,
    pub cipher: GroupCipher,
    pub member_keys: BTreeMap<String, (String, DeviceKeypair)>,
    pub repo: LedgerRepository,
    pub default_fx_rates: Vec<FxRateSpec>,
    pub custom_categories: Vec<UiExpenseCategory>,
    pub webdav_enabled: bool,
    pub webdav_endpoint: String,
    pub webdav_username: String,
    pub webdav_remote: InMemoryWebDavStore,
    pub lan_multicast_lock: bool,
    pub lan_ap_isolation: bool,
    pub optical_outgoing_frames: Vec<OpticalQrFrame>,
    pub optical_slow_mode: bool,
    pub optical_assembler: OpticalFountainAssembler,
    pub optical_last_completed: bool,
    pub last_sync_report: Option<UiSyncActivityReport>,
    pub simulated_peer_counter: u64,
}

impl WorkspaceSession {
    pub(crate) fn empty_on_repo(
        repo: LedgerRepository,
        db_path: Option<String>,
        group_id: String,
        active_actor_id: String,
        device_id: String,
        keypair: DeviceKeypair,
        cipher: GroupCipher,
    ) -> Self {
        let mut member_keys = BTreeMap::new();
        member_keys.insert(active_actor_id.clone(), (device_id, keypair));
        Self {
            repo, db_path, group_id, active_actor_id, cipher, member_keys,
            default_fx_rates: Vec::new(), custom_categories: Vec::new(),
            webdav_enabled: false, webdav_endpoint: String::new(),
            webdav_username: String::new(), webdav_remote: InMemoryWebDavStore::new(),
            lan_multicast_lock: false, lan_ap_isolation: false,
            optical_outgoing_frames: Vec::new(), optical_slow_mode: false,
            optical_assembler: OpticalFountainAssembler::new(), optical_last_completed: false,
            last_sync_report: None, simulated_peer_counter: 100,
        }
    }

    pub fn new_with_sample_trip() -> CoreResult<Self> {
        let repo = LedgerRepository::open_in_memory()?;
        Self::seed_into_repo(repo, None)
    }

    /// Opens an existing SQLite ledger file on disk (preserving all user bills, revisions,
    /// member keys, FX rates, and active persona across app restarts), or seeds initial sample
    /// data only when the database file is empty on first install.
    pub fn open_or_init_persistent(db_path: impl AsRef<Path>) -> CoreResult<Self> {
        let path_ref = db_path.as_ref();
        if let Some(parent) = path_ref.parent() {
            if !parent.as_os_str().is_empty() {
                let _ = std::fs::create_dir_all(parent);
            }
        }
        let path_str = path_ref.to_string_lossy().to_string();
        let repo = LedgerRepository::open_file(path_ref)?;

        if repo.total_event_count()? == 0 {
            return Self::seed_into_repo(repo, Some(path_str));
        }

        let group_id = repo.get_meta("group_id")?
            .ok_or_else(|| CoreError::Policy("账本缺少 group_id，不能用演示身份恢复".into()))?;
        let active_actor_id = repo.get_meta("active_actor_id")?
            .ok_or_else(|| CoreError::Policy("账本缺少本机成员身份".into()))?;
        let cipher = GroupCipher::from_b64(&repo.get_meta("cipher_b64")?
            .ok_or_else(|| CoreError::Policy("账本加密密钥丢失".into()))?, 1)?;
        let default_fx_rates: Vec<FxRateSpec> = repo
            .get_meta("default_fx_rates")?
            .map(|raw| serde_json::from_str(&raw))
            .transpose()?
            .unwrap_or_default();
        let webdav_endpoint = repo
            .get_meta("webdav_endpoint")?
            .unwrap_or_else(|| "https://nas.local:5006/webdav/sbill_app".to_string());
        let webdav_username = repo
            .get_meta("webdav_username")?
            .unwrap_or_else(|| "sbill_trip_member".to_string());
        let webdav_unreachable = repo
            .get_meta("webdav_unreachable")?
            .map(|v| v == "true")
            .unwrap_or(false);
        let simulated_peer_counter = repo
            .get_meta("simulated_peer_counter")?
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(100);
        let custom_categories: Vec<UiExpenseCategory> = repo
            .get_meta("custom_categories")?
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default();

        let mut member_keys = BTreeMap::new();
        let loaded_keys = repo.load_member_keys()?;
        if loaded_keys.is_empty() {
            return Err(CoreError::Policy("本机签名密钥丢失，不能代造成员身份".into()));
        }
        for (member_id, (dev_id, secret)) in loaded_keys {
            member_keys.insert(member_id, (dev_id, DeviceKeypair::from_secret_bytes(&secret)));
        }

        let mut webdav_remote = InMemoryWebDavStore::new();
        for (dir, hash, ct) in repo.load_webdav_mirror_objects()? {
            let _ = webdav_remote.put_encrypted_object(&dir, &hash, &ct);
        }
        webdav_remote.fail_writes = webdav_unreachable;

        let webdav_enabled = repo.get_meta("webdav_enabled")?.map(|v| v == "true").unwrap_or(true);
        let optical_outgoing_frames: Vec<OpticalQrFrame> = repo
            .get_meta("optical_outgoing_frames")?
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default();
        let optical_assembler: OpticalFountainAssembler = repo
            .get_meta("optical_assembler")?
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default();
        let optical_slow_mode = repo
            .get_meta("optical_slow_mode")?
            .map(|v| v == "true")
            .unwrap_or(false);
        let session = Self {
            db_path: Some(path_str),
            group_id,
            active_actor_id,
            cipher,
            member_keys,
            repo,
            default_fx_rates,
            custom_categories,
            webdav_enabled,
            webdav_endpoint,
            webdav_username,
            webdav_remote,
            lan_multicast_lock: true,
            lan_ap_isolation: false,
            optical_outgoing_frames,
            optical_slow_mode,
            optical_assembler,
            optical_last_completed: false,
            last_sync_report: None,
            simulated_peer_counter,
        };
        Ok(session)
    }

    pub fn persist_session_metadata(&self) -> CoreResult<()> {
        self.repo.set_meta("webdav_enabled", if self.webdav_enabled { "true" } else { "false" })?;
        self.repo.set_meta("group_id", &self.group_id)?;
        self.repo
            .set_meta("active_actor_id", &self.active_actor_id)?;
        self.repo.set_meta("cipher_b64", &self.cipher.to_b64())?;
        self.repo.set_meta(
            "default_fx_rates",
            &serde_json::to_string(&self.default_fx_rates)?,
        )?;
        self.repo
            .set_meta("webdav_endpoint", &self.webdav_endpoint)?;
        self.repo
            .set_meta("webdav_username", &self.webdav_username)?;
        self.repo.set_meta(
            "webdav_unreachable",
            if self.webdav_remote.fail_writes {
                "true"
            } else {
                "false"
            },
        )?;
        self.repo.set_meta(
            "simulated_peer_counter",
            &self.simulated_peer_counter.to_string(),
        )?;
        self.repo.set_meta(
            "custom_categories",
            &serde_json::to_string(&self.custom_categories)?,
        )?;
        self.repo.set_meta(
            "optical_outgoing_frames",
            &serde_json::to_string(&self.optical_outgoing_frames)?,
        )?;
        self.repo.set_meta(
            "optical_assembler",
            &serde_json::to_string(&self.optical_assembler)?,
        )?;
        self.repo.set_meta(
            "optical_slow_mode",
            if self.optical_slow_mode { "true" } else { "false" },
        )?;

        for (member_id, (dev_id, kp)) in &self.member_keys {
            self.repo
                .save_member_key(member_id, dev_id, &kp.secret_bytes())?;
        }

        let opaque_dir = opaque_group_directory_id(&self.group_id);
        if let Ok(hashes) = self.webdav_remote.list_encrypted_objects(&opaque_dir) {
            for h in hashes {
                if let Ok(ct) = self.webdav_remote.get_encrypted_object(&opaque_dir, &h) {
                    let _ = self.repo.save_webdav_mirror_object(&opaque_dir, &h, &ct);
                }
            }
        }
        Ok(())
    }

    fn seed_into_repo(repo: LedgerRepository, db_path: Option<String>) -> CoreResult<Self> {
        let group_id = "trip_autumn_2026".to_string();
        let cipher = GroupCipher::from_raw([77u8; 32], 1);
        let mut repo = repo;

        let kp_a = DeviceKeypair::from_secret_bytes(&[11u8; 32]);
        let kp_b = DeviceKeypair::from_secret_bytes(&[22u8; 32]);
        let kp_c = DeviceKeypair::from_secret_bytes(&[33u8; 32]);
        let kp_d = DeviceKeypair::from_secret_bytes(&[44u8; 32]);

        let mut member_keys = BTreeMap::new();
        member_keys.insert("A".to_string(), ("dev_a".to_string(), kp_a.clone()));
        member_keys.insert("B".to_string(), ("dev_b".to_string(), kp_b.clone()));
        member_keys.insert("C".to_string(), ("dev_c".to_string(), kp_c.clone()));
        member_keys.insert("D".to_string(), ("dev_d".to_string(), kp_d.clone()));

        let mut participants = BTreeMap::new();
        participants.insert(
            "A".to_string(),
            ParticipantProfile {
                participant_id: "A".to_string(),
                display_name: "阿杰 (群主)".to_string(),
                bound_public_key: Some(kp_a.public_key_b64()),
                role: Role::Owner,
                active: true,
                extra_capabilities: BTreeSet::new(),
            },
        );
        participants.insert(
            "B".to_string(),
            ParticipantProfile {
                participant_id: "B".to_string(),
                display_name: "白露 (财务管理员)".to_string(),
                bound_public_key: Some(kp_b.public_key_b64()),
                role: Role::FinanceEditor,
                active: true,
                extra_capabilities: BTreeSet::new(),
            },
        );
        participants.insert(
            "C".to_string(),
            ParticipantProfile {
                participant_id: "C".to_string(),
                display_name: "程远 (成员)".to_string(),
                bound_public_key: Some(kp_c.public_key_b64()),
                role: Role::Member,
                active: true,
                extra_capabilities: BTreeSet::new(),
            },
        );
        participants.insert(
            "D".to_string(),
            ParticipantProfile {
                participant_id: "D".to_string(),
                display_name: "丁宁 (成员)".to_string(),
                bound_public_key: Some(kp_d.public_key_b64()),
                role: Role::Member,
                active: true,
                extra_capabilities: BTreeSet::new(),
            },
        );

        let genesis_policy = PolicyPayload {
            policy_seq: 1,
            previous_policy_event_id: None,
            group_name: "川西·东京秋日同行账本".to_string(),
            owner_member_id: "A".to_string(),
            settlement_coordinator_id: "A".to_string(),
            currencies: CurrencySpec::default_catalog(),
            participants,
            accepted_device_checkpoints: BTreeMap::new(),
        };

        let genesis_ev = SignedEvent::sign_new(
            UnsignedEvent {
                schema_version: CURRENT_SCHEMA_VERSION,
                group_id: group_id.clone(),
                author_member_id: "A".to_string(),
                author_public_key: kp_a.public_key_b64(),
                device_id: "dev_a".to_string(),
                sequence: 1,
                previous_event_id: None,
                policy_version_id: "GENESIS".to_string(),
                body: EventBody::PolicyUpdate(genesis_policy),
            },
            &kp_a,
        )?;
        repo.append_signed_event(&genesis_ev, Some(&cipher))?;

        let mut session = Self {
            db_path,
            group_id,
            active_actor_id: "A".to_string(),
            cipher,
            member_keys,
            repo,
            default_fx_rates: vec![
                FxRateSpec::new("USD", "CNY", 7, 1)?,
                FxRateSpec::new("JPY", "CNY", 1, 20)?,
                FxRateSpec::new("EUR", "CNY", 8, 1)?,
                FxRateSpec::new("HKD", "CNY", 9, 10)?,
            ],
            custom_categories: Vec::new(),
            webdav_enabled: true,
            webdav_endpoint: "https://nas.local:5006/webdav/sbill_app".to_string(),
            webdav_username: "sbill_trip_member".to_string(),
            webdav_remote: InMemoryWebDavStore::new(),
            lan_multicast_lock: true,
            lan_ap_isolation: false,
            optical_outgoing_frames: Vec::new(),
            optical_slow_mode: false,
            optical_assembler: OpticalFountainAssembler::new(),
            optical_last_completed: false,
            last_sync_report: None,
            simulated_peer_counter: 100,
        };

        session.upsert_expense(
            "A",
            "exp_hotel_cny",
            vec![],
            "CNY",
            100_000,
            vec![
                PayerContribution {
                    participant_id: "A".to_string(),
                    amount_minor: 60_000,
                    original_currency: None,
                    original_amount_minor: None,
                    frozen_fx_rate: None,
                },
                PayerContribution {
                    participant_id: "B".to_string(),
                    amount_minor: 40_000,
                    original_currency: None,
                    original_amount_minor: None,
                    frozen_fx_rate: None,
                },
            ],
            SplitRule::Equal {
                participants: vec![
                    "A".to_string(),
                    "B".to_string(),
                    "C".to_string(),
                    "D".to_string(),
                ],
            },
            "温泉酒店两晚合住",
            "A垫付600元，B垫付400元，四人平摊",
            "创建账单",
            false,
        )?;

        session.upsert_expense(
            "C",
            "exp_dinner_usd",
            vec![],
            "USD",
            10_000,
            vec![PayerContribution {
                participant_id: "C".to_string(),
                amount_minor: 10_000,
                original_currency: None,
                original_amount_minor: None,
                frozen_fx_rate: None,
            }],
            SplitRule::Equal {
                participants: vec![
                    "A".to_string(),
                    "B".to_string(),
                    "C".to_string(),
                    "D".to_string(),
                ],
            },
            "抵达首日晚餐 (USD)",
            "程远刷美元卡垫付 100 USD",
            "创建账单",
            false,
        )?;

        session.generate_optical_frames(180, 6, false)?;
        session.persist_session_metadata()?;

        Ok(session)
    }

    pub fn set_fx_rate(
        &mut self,
        base_currency: &str,
        quote_currency: &str,
        numerator: i64,
        denominator: i64,
    ) -> CoreResult<()> {
        let new_rate = FxRateSpec::new(base_currency, quote_currency, numerator, denominator)?;
        if let Some(existing) = self.default_fx_rates.iter_mut().find(|r| {
            (r.base_currency == base_currency && r.quote_currency == quote_currency)
                || (r.base_currency == quote_currency && r.quote_currency == base_currency)
        }) {
            *existing = new_rate;
        } else {
            self.default_fx_rates.push(new_rate);
        }
        Ok(())
    }

    /// Creates a signed `CategoryUpsert` event in the append-only ledger so custom categories
    /// automatically sync across all peers (LAN, .tripdelta file, WebDAV, Optical QR) and merge
    /// as a deterministic Set Union.
    pub fn upsert_custom_category(
        &mut self,
        actor_id: &str,
        category_id: &str,
        icon: &str,
        name: &str,
        deleted: bool,
    ) -> CoreResult<SignedEvent> {
        let (device_id, keypair) = self.member_keys.get(actor_id).cloned().ok_or_else(|| {
            CoreError::NotFound(format!("actor '{actor_id}' has no local signing key"))
        })?;
        let proj = self.repo.project_group(&self.group_id)?;
        let (seq, prev_ev) = self.repo.next_device_sequence(&self.group_id, &device_id)?;
        let unsigned = UnsignedEvent {
            schema_version: CURRENT_SCHEMA_VERSION,
            group_id: self.group_id.clone(),
            author_member_id: actor_id.to_string(),
            author_public_key: keypair.public_key_b64(),
            device_id,
            sequence: seq,
            previous_event_id: prev_ev,
            policy_version_id: proj.active_policy_event_id,
            body: EventBody::CategoryUpsert(CustomCategoryUpsertPayload {
                category_id: category_id.to_string(),
                icon: icon.to_string(),
                name: name.to_string(),
                deleted,
                observed_add_event_ids: if deleted {
                    observed_category_tags(&self.repo.list_events(&self.group_id)?, category_id, name)
                } else { Vec::new() },
            }),
        };
        let signed = SignedEvent::sign_new(unsigned, &keypair)?;
        self.repo.append_signed_event(&signed, Some(&self.cipher))?;
        Ok(signed)
    }

    pub fn export_tripdelta(&mut self) -> CoreResult<()> {
        let events = self.repo.list_events(&self.group_id)?;
        let pkg = TripDeltaPackage::pack_events(&self.group_id, &events, &self.cipher)?;
        let raw_bytes = pkg.to_bytes()?;
        let json_str = String::from_utf8(raw_bytes.clone())
            .map_err(|e| CoreError::SyncPackage(format!("invalid utf8 package: {e}")))?;
        let compact_code = format!("{COMPACT_TEXT_PREFIX}{}", URL_SAFE_NO_PAD.encode(&raw_bytes));

        self.last_sync_report = Some(UiSyncActivityReport {
            channel: "文件互传 (.tripdelta)".to_string(),
            summary_title: format!(
                "已打包 {} 条签名事件 ({} 字节)",
                pkg.event_count,
                raw_bytes.len()
            ),
            added_events: 0,
            duplicate_events: pkg.event_count,
            rejected_or_tampered: 0,
            uploaded_objects: 0,
            failed_uploads: 0,
            package_byte_len: raw_bytes.len(),
            package_digest: Some(pkg.package_digest),
            exported_tripdelta_json: Some(json_str),
            exported_compact_code: Some(compact_code),
        });
        Ok(())
    }

    pub fn import_tripdelta_payload(&mut self, payload_raw: &str) -> CoreResult<()> {
        let max_text_bytes = (crate::crypto::SYNC_PACK_MAX_COMPRESSED_BYTES + 4096).div_ceil(3) * 4 + COMPACT_TEXT_PREFIX.len();
        if payload_raw.len() > max_text_bytes {
            return Err(CoreError::SyncPackage("同步内容超过解码包限额".into()));
        }
        let trimmed = payload_raw.trim();
        if trimmed.is_empty() {
            return Err(CoreError::SyncPackage("导入内容不能为空".to_string()));
        }
        let raw_bytes = if let Some(b64_part) = trimmed.strip_prefix(COMPACT_TEXT_PREFIX) {
            URL_SAFE_NO_PAD.decode(b64_part).map_err(|e| {
                CoreError::SyncPackage(format!("紧凑同步码 Base64 解码失败（可能复制被截断）: {e}"))
            })?
        } else {
            trimmed.as_bytes().to_vec()
        };

        let pkg = TripDeltaPackage::from_bytes(&raw_bytes)?;
        let events = pkg.unpack_events(&self.group_id, &self.cipher)?;
        let summary = self
            .repo
            .import_event_batch(&self.group_id, &events, Some(&self.cipher))?;

        if !summary.rejected_events.is_empty() {
            return Err(CoreError::SyncPackage(format!("整包未导入，账目未改变：{}", summary.rejected_events[0].1)));
        }
        self.last_sync_report = Some(UiSyncActivityReport {
            channel: "导入 .tripdelta 同步包".to_string(),
            summary_title: format!(
                "整包导入：新增 {} 条，重复 {} 条，待依赖 {} 条，待重授权 {} 条",
                summary.added_count,
                summary.duplicate_count,
                summary.pending_dependency_count,
                summary.pending_reauth_count
            ),
            added_events: summary.added_count,
            duplicate_events: summary.duplicate_count,
            rejected_or_tampered: summary.rejected_events.len(),
            uploaded_objects: 0,
            failed_uploads: 0,
            package_byte_len: raw_bytes.len(),
            package_digest: Some(pkg.package_digest),
            exported_tripdelta_json: None,
            exported_compact_code: None,
        });
        Ok(())
    }

    pub fn simulate_peer_incoming_tripdelta(&mut self, auto_import: bool) -> CoreResult<()> {
        self.simulated_peer_counter += 1;
        let idx = self.simulated_peer_counter;
        let ev = self.make_peer_expense_event(
            "D",
            &format!("dev_d_ext_{idx}"),
            1,
            None,
            &format!("exp_peer_delta_{idx}"),
            32_000,
            &format!("同伴互传账单 #{idx} (景区观光车)"),
            "由丁宁手机离线生成并通过 .tripdelta 互传导入",
        )?;

        let pkg = TripDeltaPackage::pack_events(&self.group_id, &[ev], &self.cipher)?;
        let raw_bytes = pkg.to_bytes()?;
        let json_str = String::from_utf8(raw_bytes.clone()).unwrap();
        let compact_code = format!("{COMPACT_TEXT_PREFIX}{}", URL_SAFE_NO_PAD.encode(&raw_bytes));

        if auto_import {
            self.import_tripdelta_payload(&json_str)?;
            if let Some(rep) = &mut self.last_sync_report {
                rep.exported_tripdelta_json = Some(json_str);
                rep.exported_compact_code = Some(compact_code);
            }
        } else {
            self.last_sync_report = Some(UiSyncActivityReport {
                channel: "模拟同伴生成 .tripdelta".to_string(),
                summary_title: "已生成同伴丁宁的外部 .tripdelta 增量包，可点击导入或复制".to_string(),
                added_events: 0,
                duplicate_events: 0,
                rejected_or_tampered: 0,
                uploaded_objects: 0,
                failed_uploads: 0,
                package_byte_len: raw_bytes.len(),
                package_digest: Some(pkg.package_digest),
                exported_tripdelta_json: Some(json_str),
                exported_compact_code: Some(compact_code),
            });
        }
        Ok(())
    }

    pub fn configure_webdav(
        &mut self,
        endpoint_url: &str,
        username: &str,
        simulate_unreachable: bool,
    ) -> CoreResult<()> {
        if endpoint_url.trim().is_empty() {
            return Err(CoreError::SyncPackage("WebDAV 地址不能为空".to_string()));
        }
        self.webdav_enabled = true;
        self.webdav_endpoint = endpoint_url.trim().to_string();
        self.webdav_username = username.trim().to_string();
        self.webdav_remote.fail_writes = simulate_unreachable;
        Ok(())
    }

    pub fn sync_webdav_now(&mut self) -> CoreResult<()> {
        let report = sync_with_webdav(
            &mut self.repo,
            &self.group_id,
            &self.cipher,
            &mut self.webdav_remote,
        )?;
        let status_title = if report.failed_uploads > 0 {
            format!(
                "WebDAV 暂不可达：{} 个密文对象保留在待传队列（不影响本地记账与互传）",
                report.failed_uploads
            )
        } else {
            format!(
                "WebDAV 同步完成：上传 {} 个对象，拉取新增 {} 条事件，拦截篡改 {} 个",
                report.uploaded_objects,
                report.downloaded_events,
                report.tampered_or_rejected_objects
            )
        };
        self.last_sync_report = Some(UiSyncActivityReport {
            channel: "WebDAV 异步留存通道".to_string(),
            summary_title: status_title,
            added_events: report.downloaded_events,
            duplicate_events: report.duplicate_events,
            rejected_or_tampered: report.tampered_or_rejected_objects,
            uploaded_objects: report.uploaded_objects,
            failed_uploads: report.failed_uploads,
            package_byte_len: 0,
            package_digest: None,
            exported_tripdelta_json: None,
            exported_compact_code: None,
        });
        Ok(())
    }

    pub fn simulate_remote_webdav_incoming(&mut self, inject_tampered: bool) -> CoreResult<()> {
        self.simulated_peer_counter += 1;
        let idx = self.simulated_peer_counter;
        let ev = self.make_peer_expense_event(
            "C",
            &format!("dev_c_remote_{idx}"),
            1,
            None,
            &format!("exp_webdav_async_{idx}"),
            24_000,
            &format!("错峰留存账单 #{idx} (夜间便利店补给)"),
            "程远夜间上传至 WebDAV 留存节点，其他成员次日上线拉取",
        )?;

        let raw_json = canonical_json_bytes(&ev)?;
        let aad = format!("sbill:v1:event:{}", self.group_id);
        let ciphertext = self.cipher.encrypt(&raw_json, aad.as_bytes())?;
        let obj_hash = blake3_hash_b64(&ciphertext);
        let dir = opaque_group_directory_id(&self.group_id);

        let prev_fail = self.webdav_remote.fail_writes;
        self.webdav_remote.fail_writes = false;
        self.webdav_remote
            .put_encrypted_object(&dir, &obj_hash, &ciphertext)?;
        if inject_tampered {
            self.webdav_remote.put_encrypted_object(
                &dir,
                &format!("tampered_obj_{idx}"),
                b"corrupted_server_ciphertext_payload",
            )?;
        }
        self.webdav_remote.fail_writes = prev_fail;
        Ok(())
    }

    /// Configures LAN discovery and hotel Wi-Fi AP isolation state (M7 AC-L01, AC-L02).
    pub fn configure_lan_discovery(&mut self, ap_isolation_detected: bool) -> CoreResult<()> {
        self.lan_ap_isolation = ap_isolation_detected;
        if ap_isolation_detected {
            self.last_sync_report = Some(UiSyncActivityReport {
                channel: "局域网直连 (LAN)".to_string(),
                summary_title:
                    "检测到当前 Wi-Fi 开启了 AP 客户端隔离，建议切换手机热点、系统互传或动态二维码通道 (AC-L02)"
                        .to_string(),
                added_events: 0,
                duplicate_events: 0,
                rejected_or_tampered: 0,
                uploaded_objects: 0,
                failed_uploads: 0,
                package_byte_len: 0,
                package_digest: None,
                exported_tripdelta_json: None,
                exported_compact_code: None,
            });
        }
        Ok(())
    }

    /// Performs a LAN direct incremental sync with a discovered peer, including mid-stream sequence
    /// gap detection and precision gap filling (M7 AC-L01, AC-L04, AC-L05).
    pub fn sync_lan_with_discovered_peer(
        &mut self,
        peer_member_id: &str,
        simulate_gap_fill: bool,
    ) -> CoreResult<()> {
        if self.lan_ap_isolation {
            return Err(CoreError::SyncPackage(
                "当前路由器启用了 AP 客户端隔离，局域网设备无法直接互通，请切换手机热点或使用动态二维码/文件互传 (AC-L02)"
                    .to_string(),
            ));
        }

        self.simulated_peer_counter += 1;
        let idx = self.simulated_peer_counter;
        let peer_dev = format!("dev_{}_lan_{idx}", peer_member_id.to_lowercase());

        let ev1 = self.make_peer_expense_event(
            peer_member_id,
            &peer_dev,
            1,
            None,
            &format!("exp_lan_{idx}_1"),
            16_000,
            &format!("局域网同步账单 #{idx}-1 (山地缆车)"),
            "无公网环境下通过局域网直连同步",
        )?;
        let ev2 = self.make_peer_expense_event(
            peer_member_id,
            &peer_dev,
            2,
            Some(ev1.event_id.clone()),
            &format!("exp_lan_{idx}_2"),
            8_000,
            &format!("局域网同步账单 #{idx}-2 (山顶热饮)"),
            "无公网环境下通过局域网直连同步",
        )?;

        if simulate_gap_fill {
            // Step 1: Receive seq=2 out-of-order first -> enters PendingDependency with missing_seqs=[1]
            let st = self.repo.append_signed_event(&ev2, Some(&self.cipher))?;
            debug_assert_eq!(st, EventApplyStatus::PendingDependency);

            // Step 2: PeerSyncSummary identifies missing seq=1, and LAN sync fills the gap!
            let my_summary = self.repo.build_sync_summary(&self.group_id)?;
            debug_assert_eq!(my_summary.device_cursors[&peer_dev].missing_seqs, vec![1]);
            let summary = self
                .repo
                .import_event_batch(&self.group_id, &[ev1], Some(&self.cipher))?;

            self.last_sync_report = Some(UiSyncActivityReport {
                channel: "局域网无公网直连 (LAN + 缺口补齐)".to_string(),
                summary_title: format!(
                    "已与成员 {peer_member_id} 完成无公网直连同步，精准补齐序号缺口并激活 2 条账单 (AC-L04)"
                ),
                added_events: summary.added_count + 1,
                duplicate_events: summary.duplicate_count,
                rejected_or_tampered: 0,
                uploaded_objects: 0,
                failed_uploads: 0,
                package_byte_len: 0,
                package_digest: None,
                exported_tripdelta_json: None,
                exported_compact_code: None,
            });
        } else {
            let summary = self
                .repo
                .import_event_batch(&self.group_id, &[ev1], Some(&self.cipher))?;
            self.last_sync_report = Some(UiSyncActivityReport {
                channel: "局域网无公网直连 (LAN)".to_string(),
                summary_title: format!(
                    "已与成员 {peer_member_id} 完成局域网直连增量同步：新增 {} 条事件 (AC-L01)",
                    summary.added_count
                ),
                added_events: summary.added_count,
                duplicate_events: summary.duplicate_count,
                rejected_or_tampered: 0,
                uploaded_objects: 0,
                failed_uploads: 0,
                package_byte_len: 0,
                package_digest: None,
                exported_tripdelta_json: None,
                exported_compact_code: None,
            });
        }
        Ok(())
    }

    /// Encodes the local ledger events into fountain-coded `OpticalQrFrame`s (M7 AC-Q01..Q05).
    pub fn generate_optical_frames(
        &mut self,
        slice_byte_len: usize,
        parity_frames: usize,
        slow_mode: bool,
    ) -> CoreResult<()> {
        let events = self.repo.list_events(&self.group_id)?;
        let pkg = TripDeltaPackage::pack_events(&self.group_id, &events, &self.cipher)?;
        let frames =
            encode_optical_fountain_frames(&pkg, slice_byte_len.clamp(80, 600), parity_frames)?;
        self.optical_outgoing_frames = frames;
        self.optical_slow_mode = slow_mode;
        Ok(())
    }

    /// Feeds a single scanned `OpticalQrFrame` JSON into the peeling fountain decoder (M7 AC-Q02, AC-Q03).
    pub fn ingest_optical_frame_json(&mut self, frame_json: &str) -> CoreResult<()> {
        let frame: OpticalQrFrame = serde_json::from_str(frame_json)
            .map_err(|e| CoreError::SyncPackage(format!("二维码帧 JSON 解析失败: {e}")))?;
        self.optical_last_completed = false;
        if let Some(recovered_pkg) = self.optical_assembler.ingest_frame(&frame)? {
            self.optical_last_completed = true;
            let events = recovered_pkg.unpack_events(&self.group_id, &self.cipher)?;
            let summary =
                self.repo
                    .import_event_batch(&self.group_id, &events, Some(&self.cipher))?;
            self.last_sync_report = Some(UiSyncActivityReport {
                channel: "动态二维码光学通道 (UR/喷泉码)".to_string(),
                summary_title: format!(
                    "喷泉码恢复完成并验签入账：新增 {} 条，重复跳过 {} 条",
                    summary.added_count, summary.duplicate_count
                ),
                added_events: summary.added_count,
                duplicate_events: summary.duplicate_count,
                rejected_or_tampered: summary.rejected_events.len(),
                uploaded_objects: 0,
                failed_uploads: 0,
                package_byte_len: frame.total_byte_len,
                package_digest: Some(recovered_pkg.package_digest),
                exported_tripdelta_json: None,
                exported_compact_code: None,
            });
        }
        Ok(())
    }

    /// Simulates a complete airgapped camera scan of a peer's animated QR stream,
    /// starting mid-stream after dropping the first 2 source frames and recovering via fountain parity frames!
    pub fn simulate_optical_airgap_transfer(
        &mut self,
        drop_first_two_frames: bool,
    ) -> CoreResult<()> {
        self.simulated_peer_counter += 1;
        let idx = self.simulated_peer_counter;
        let ev = self.make_peer_expense_event(
            "B",
            &format!("dev_b_optical_{idx}"),
            1,
            None,
            &format!("exp_optical_qr_{idx}"),
            28_000,
            &format!("扫码面对面同步账单 #{idx} (高原露营向导费)"),
            "完全无 Wi-Fi/蜂窝/蓝牙环境下通过动态二维码喷泉码面对面同步",
        )?;

        let pkg = TripDeltaPackage::pack_events(&self.group_id, &[ev], &self.cipher)?;
        let frames = encode_optical_fountain_frames(&pkg, 160, 10)?;
        let skip_count = if drop_first_two_frames && frames.len() > 4 {
            2
        } else {
            0
        };

        self.optical_assembler = OpticalFountainAssembler::new();
        self.optical_last_completed = false;

        for frame in frames.iter().skip(skip_count) {
            let raw = serde_json::to_string(frame)?;
            self.ingest_optical_frame_json(&raw)?;
            if self.optical_last_completed {
                break;
            }
        }
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    fn make_peer_expense_event(
        &self,
        actor_id: &str,
        device_id: &str,
        sequence: u64,
        previous_event_id: Option<String>,
        expense_id: &str,
        total_minor: i64,
        title: &str,
        note: &str,
    ) -> CoreResult<SignedEvent> {
        let (_, kp) = self.member_keys.get(actor_id).cloned().ok_or_else(|| {
            CoreError::NotFound(format!("actor '{actor_id}' has no local signing key"))
        })?;
        let proj = self.repo.project_group(&self.group_id)?;
        let split_rule = SplitRule::Equal {
            participants: vec![
                "A".to_string(),
                "B".to_string(),
                "C".to_string(),
                "D".to_string(),
            ],
        };
        let resolved_shares = compute_resolved_shares(total_minor, &split_rule, false)?;
        let payers = vec![PayerContribution {
            participant_id: actor_id.to_string(),
            amount_minor: total_minor,
            original_currency: None,
            original_amount_minor: None,
            frozen_fx_rate: None,
        }];
        let attribution_matrix =
            compute_attribution_matrix(total_minor, &payers, &resolved_shares, false)?;

        let payload = ExpenseRevisionPayload {
            expense_id: expense_id.to_string(),
            parent_revision_event_ids: vec![],
            currency: "CNY".to_string(),
            total_minor,
            payers,
            split_rule,
            resolved_shares,
            attribution_matrix,
            attribution_rule_version: ATTRIBUTION_RULE_VERSION.to_string(),
            details: None,
            title: title.to_string(),
            note: note.to_string(),
            revision_reason: "同伴创建".to_string(),
            attachment_refs: vec![],
            voided: false,
        };

        SignedEvent::sign_new(
            UnsignedEvent {
                schema_version: CURRENT_SCHEMA_VERSION,
                group_id: self.group_id.clone(),
                author_member_id: actor_id.to_string(),
                author_public_key: kp.public_key_b64(),
                device_id: device_id.to_string(),
                sequence,
                previous_event_id,
                policy_version_id: proj.active_policy_event_id,
                body: EventBody::ExpenseUpsert(payload),
            },
            &kp,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn upsert_expense(
        &mut self,
        actor_id: &str,
        expense_id: &str,
        parent_revision_event_ids: Vec<String>,
        currency: &str,
        total_minor: i64,
        payers: Vec<PayerContribution>,
        split_rule: SplitRule,
        title: &str,
        note: &str,
        revision_reason: &str,
        voided: bool,
    ) -> CoreResult<SignedEvent> {
        self.upsert_expense_with_details(actor_id, expense_id, parent_revision_event_ids,
            currency, total_minor, payers, split_rule, title, note, revision_reason, voided, None)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn upsert_expense_with_details(
        &mut self,
        actor_id: &str,
        expense_id: &str,
        parent_revision_event_ids: Vec<String>,
        currency: &str,
        total_minor: i64,
        payers: Vec<PayerContribution>,
        split_rule: SplitRule,
        title: &str,
        note: &str,
        revision_reason: &str,
        voided: bool,
        details: Option<crate::domain::ExpenseDetails>,
    ) -> CoreResult<SignedEvent> {
        let details = match details {
            Some(details) => Some(details),
            None => crate::storage::expense_details_from_parents(
                &self.repo.list_events(&self.group_id)?, expense_id, &parent_revision_event_ids)?,
        };
        let (device_id, keypair) = self.member_keys.get(actor_id).cloned().ok_or_else(|| {
            CoreError::NotFound(format!("actor '{actor_id}' has no local signing key"))
        })?;

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
            attachment_refs: vec![],
            voided,
        };

        let (seq, prev_ev) = self.repo.next_device_sequence(&self.group_id, &device_id)?;
        let unsigned = UnsignedEvent {
            schema_version: CURRENT_SCHEMA_VERSION,
            group_id: self.group_id.clone(),
            author_member_id: actor_id.to_string(),
            author_public_key: keypair.public_key_b64(),
            device_id,
            sequence: seq,
            previous_event_id: prev_ev,
            policy_version_id: proj.active_policy_event_id,
            body: EventBody::ExpenseUpsert(payload),
        };
        let signed = SignedEvent::sign_new(unsigned, &keypair)?;
        self.repo.append_signed_event(&signed, Some(&self.cipher))?;
        Ok(signed)
    }

    pub fn add_participant(
        &mut self,
        actor_id: &str,
        participant_id: &str,
        display_name: &str,
        role: Role,
        bind_device_key: bool,
    ) -> CoreResult<SignedEvent> {
        let (device_id, keypair) = self.member_keys.get(actor_id).cloned().ok_or_else(|| {
            CoreError::NotFound(format!("actor '{actor_id}' has no local signing key"))
        })?;

        let proj = self.repo.project_group(&self.group_id)?;
        let mut new_pol = proj.active_policy.clone();
        new_pol.policy_seq += 1;
        new_pol.previous_policy_event_id = Some(proj.active_policy_event_id.clone());

        let bound_public_key = if bind_device_key {
            let new_kp = DeviceKeypair::generate();
            let pub_b64 = new_kp.public_key_b64();
            self.member_keys.insert(
                participant_id.to_string(),
                (format!("dev_{participant_id}"), new_kp),
            );
            Some(pub_b64)
        } else {
            None
        };

        new_pol.participants.insert(
            participant_id.to_string(),
            ParticipantProfile {
                participant_id: participant_id.to_string(),
                display_name: display_name.to_string(),
                bound_public_key,
                role,
                active: true,
                extra_capabilities: BTreeSet::new(),
            },
        );

        let (seq, prev_ev) = self.repo.next_device_sequence(&self.group_id, &device_id)?;
        let unsigned = UnsignedEvent {
            schema_version: CURRENT_SCHEMA_VERSION,
            group_id: self.group_id.clone(),
            author_member_id: actor_id.to_string(),
            author_public_key: keypair.public_key_b64(),
            device_id,
            sequence: seq,
            previous_event_id: prev_ev,
            policy_version_id: proj.active_policy_event_id,
            body: EventBody::PolicyUpdate(new_pol),
        };
        let signed = SignedEvent::sign_new(unsigned, &keypair)?;
        self.repo.append_signed_event(&signed, Some(&self.cipher))?;
        Ok(signed)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn declare_repayment(
        &mut self,
        actor_id: &str,
        payment_id: &str,
        payer_id: &str,
        payee_id: &str,
        currency: &str,
        amount_minor: i64,
        target_obligation_id: Option<String>,
        note: &str,
    ) -> CoreResult<SignedEvent> {
        let (device_id, keypair) = self.member_keys.get(actor_id).cloned().ok_or_else(|| {
            CoreError::NotFound(format!("actor '{actor_id}' has no local signing key"))
        })?;

        let proj = self.repo.project_group(&self.group_id)?;
        let (seq, prev_ev) = self.repo.next_device_sequence(&self.group_id, &device_id)?;
        let unsigned = UnsignedEvent {
            schema_version: CURRENT_SCHEMA_VERSION,
            group_id: self.group_id.clone(),
            author_member_id: actor_id.to_string(),
            author_public_key: keypair.public_key_b64(),
            device_id,
            sequence: seq,
            previous_event_id: prev_ev,
            policy_version_id: proj.active_policy_event_id,
            body: EventBody::RepaymentDeclare(RepaymentDeclarePayload {
                payment_id: payment_id.to_string(),
                payer_id: payer_id.to_string(),
                payee_id: payee_id.to_string(),
                currency: currency.to_string(),
                amount_minor,
                target_obligation_id,
                external_reference: None,
                note: note.to_string(),
            }),
        };
        let signed = SignedEvent::sign_new(unsigned, &keypair)?;
        self.repo.append_signed_event(&signed, Some(&self.cipher))?;
        Ok(signed)
    }

    pub fn confirm_repayment(
        &mut self,
        actor_id: &str,
        payment_id: &str,
        declare_event_id: &str,
        overpayment_policy: Option<String>,
    ) -> CoreResult<SignedEvent> {
        let (device_id, keypair) = self.member_keys.get(actor_id).cloned().ok_or_else(|| {
            CoreError::NotFound(format!("actor '{actor_id}' has no local signing key"))
        })?;

        let proj = self.repo.project_group(&self.group_id)?;
        let repayment = proj.repayments.get(payment_id)
            .ok_or_else(|| CoreError::NotFound("还款声明不存在".into()))?;
        if repayment.declare_event_id != declare_event_id {
            return Err(CoreError::Settlement("确认引用的还款声明不匹配".into()));
        }
        let (seq, prev_ev) = self.repo.next_device_sequence(&self.group_id, &device_id)?;
        let unsigned = UnsignedEvent {
            schema_version: CURRENT_SCHEMA_VERSION,
            group_id: self.group_id.clone(),
            author_member_id: actor_id.to_string(),
            author_public_key: keypair.public_key_b64(),
            device_id,
            sequence: seq,
            previous_event_id: prev_ev,
            policy_version_id: proj.active_policy_event_id,
            body: EventBody::RepaymentConfirm(RepaymentConfirmPayload {
                payment_id: payment_id.to_string(),
                declare_event_id: declare_event_id.to_string(),
                overpayment_policy,
            }),
        };
        let signed = SignedEvent::sign_new(unsigned, &keypair)?;
        self.repo.append_signed_event(&signed, Some(&self.cipher))?;
        Ok(signed)
    }

    pub fn dispute_repayment(
        &mut self,
        actor_id: &str,
        payment_id: &str,
        declare_event_id: &str,
        reason: &str,
    ) -> CoreResult<SignedEvent> {
        let (device_id, keypair) = self.member_keys.get(actor_id).cloned().ok_or_else(|| {
            CoreError::NotFound(format!("actor '{actor_id}' has no local signing key"))
        })?;
        let proj = self.repo.project_group(&self.group_id)?;
        let repayment = proj
            .repayments
            .get(payment_id)
            .ok_or_else(|| CoreError::NotFound("还款声明不存在".into()))?;
        if repayment.declare_event_id != declare_event_id {
            return Err(CoreError::Settlement("异议引用的还款声明不匹配".into()));
        }
        let (seq, prev_ev) = self.repo.next_device_sequence(&self.group_id, &device_id)?;
        let unsigned = UnsignedEvent {
            schema_version: CURRENT_SCHEMA_VERSION,
            group_id: self.group_id.clone(),
            author_member_id: actor_id.to_string(),
            author_public_key: keypair.public_key_b64(),
            device_id,
            sequence: seq,
            previous_event_id: prev_ev,
            policy_version_id: proj.active_policy_event_id,
            body: EventBody::RepaymentDispute(RepaymentDisputePayload {
                payment_id: payment_id.to_string(),
                declare_event_id: declare_event_id.to_string(),
                reason: reason.trim().to_string(),
            }),
        };
        let signed = SignedEvent::sign_new(unsigned, &keypair)?;
        self.repo.append_signed_event(&signed, Some(&self.cipher))?;
        Ok(signed)
    }

    pub fn map_late_repayment(
        &mut self,
        actor_id: &str,
        payment_id: &str,
        target_obligation_id: &str,
        note: &str,
    ) -> CoreResult<SignedEvent> {
        let (device_id, keypair) = self.member_keys.get(actor_id).cloned().ok_or_else(|| {
            CoreError::NotFound(format!("actor '{actor_id}' has no local signing key"))
        })?;
        let proj = self.repo.project_group(&self.group_id)?;
        let (seq, prev_ev) = self.repo.next_device_sequence(&self.group_id, &device_id)?;
        let unsigned = UnsignedEvent {
            schema_version: CURRENT_SCHEMA_VERSION,
            group_id: self.group_id.clone(),
            author_member_id: actor_id.to_string(),
            author_public_key: keypair.public_key_b64(),
            device_id,
            sequence: seq,
            previous_event_id: prev_ev,
            policy_version_id: proj.active_policy_event_id,
            body: EventBody::RepaymentMapObligation(RepaymentMapObligationPayload {
                payment_id: payment_id.to_string(),
                target_obligation_id: target_obligation_id.to_string(),
                note: note.trim().to_string(),
            }),
        };
        let signed = SignedEvent::sign_new(unsigned, &keypair)?;
        self.repo.append_signed_event(&signed, Some(&self.cipher))?;
        Ok(signed)
    }

    pub fn export_identity_backup(&mut self, passphrase: &str) -> CoreResult<()> {
        let (device_id, keypair) = self
            .member_keys
            .get(&self.active_actor_id)
            .cloned()
            .ok_or_else(|| CoreError::NotFound("本机成员密钥不存在".into()))?;
        let backup = MemberIdentityBackup::create(
            &self.active_actor_id,
            &device_id,
            &keypair,
            passphrase,
        )?;
        let json_str = serde_json::to_string(&backup)?;
        self.last_sync_report = Some(UiSyncActivityReport {
            channel: "Argon2id 身份密钥备份".to_string(),
            summary_title: format!(
                "已使用 Argon2id (64MiB/t3) 加密导出成员 {} 的签名身份备份",
                self.active_actor_id
            ),
            added_events: 0,
            duplicate_events: 0,
            rejected_or_tampered: 0,
            uploaded_objects: 0,
            failed_uploads: 0,
            package_byte_len: json_str.len(),
            package_digest: Some(backup.public_key_b64.clone()),
            exported_tripdelta_json: None,
            exported_compact_code: Some(json_str),
        });
        Ok(())
    }

    pub fn restore_identity_backup(
        &mut self,
        backup_json: &str,
        passphrase: &str,
    ) -> CoreResult<()> {
        let backup: MemberIdentityBackup = serde_json::from_str(backup_json.trim())
            .map_err(|e| CoreError::Crypto(format!("备份格式无效: {e}")))?;
        let restored = backup.restore(passphrase)?;
        let proj = self.repo.project_group(&self.group_id)?;
        let bound_pub = proj
            .active_policy
            .participants
            .get(&backup.member_id)
            .and_then(|p| p.bound_public_key.as_deref())
            .ok_or_else(|| CoreError::Policy("该账本中不存在对应已绑定成员".into()))?;
        if bound_pub != restored.public_key_b64() {
            return Err(CoreError::Policy("备份公钥与当前账本绑定的成员身份不一致".into()));
        }
        self.member_keys.insert(
            backup.member_id.clone(),
            (backup.device_id.clone(), restored),
        );
        self.last_sync_report = Some(UiSyncActivityReport {
            channel: "Argon2id 身份密钥恢复".to_string(),
            summary_title: format!(
                "已验证并恢复成员 {} (设备 {}) 的签名私钥",
                backup.member_id, backup.device_id
            ),
            added_events: 0,
            duplicate_events: 0,
            rejected_or_tampered: 0,
            uploaded_objects: 0,
            failed_uploads: 0,
            package_byte_len: backup_json.len(),
            package_digest: Some(backup.public_key_b64),
            exported_tripdelta_json: None,
            exported_compact_code: None,
        });
        Ok(())
    }

    pub fn apply_webdav_http_sync(
        &mut self,
        uploaded_hashes: Vec<String>,
        failed_hashes: Vec<String>,
        downloaded_objects: Vec<(String, String)>,
    ) -> CoreResult<()> {
        let dir = opaque_group_directory_id(&self.group_id);
        let pending_map: BTreeMap<String, Vec<u8>> = self
            .repo
            .pending_webdav_uploads(&self.group_id)?
            .into_iter()
            .map(|(h, _, ct)| (h, ct))
            .collect();
        for hash in &uploaded_hashes {
            self.repo.mark_webdav_uploaded(hash)?;
            if let Some(ct) = pending_map.get(hash) {
                let _ = self.webdav_remote.put_encrypted_object(&dir, hash, ct);
            }
        }
        for hash in &failed_hashes {
            let _ = self.repo.record_webdav_retry(hash)?;
        }
        let aad = format!("sbill:v1:event:{}", self.group_id);
        let mut decoded_events = Vec::new();
        let mut tampered_or_rejected = 0usize;
        for (hash, ct_b64) in downloaded_objects {
            let Ok(ciphertext) = URL_SAFE_NO_PAD.decode(ct_b64.trim()) else {
                tampered_or_rejected += 1;
                continue;
            };
            if blake3_hash_b64(&ciphertext) != hash {
                tampered_or_rejected += 1;
                continue;
            }
            let Ok(plaintext) = self.cipher.decrypt(&ciphertext, aad.as_bytes()) else {
                tampered_or_rejected += 1;
                continue;
            };
            let Ok(ev) = serde_json::from_slice::<SignedEvent>(&plaintext) else {
                tampered_or_rejected += 1;
                continue;
            };
            if ev.verify_cryptographic_integrity().is_err() {
                tampered_or_rejected += 1;
                continue;
            }
            let _ = self.webdav_remote.put_encrypted_object(&dir, &hash, &ciphertext);
            decoded_events.push(ev);
        }
        let import_summary = self
            .repo
            .import_event_batch(&self.group_id, &decoded_events, None)?;
        tampered_or_rejected += import_summary.rejected_events.len();
        let status_title = if !failed_hashes.is_empty() {
            format!(
                "WebDAV 同步部分失败：已上传 {} 个，待重试 {} 个，拉取新增 {} 条",
                uploaded_hashes.len(),
                failed_hashes.len(),
                import_summary.added_count
            )
        } else {
            format!(
                "WebDAV 同步完成：上传 {} 个对象，拉取新增 {} 条事件，拦截篡改 {} 个",
                uploaded_hashes.len(),
                import_summary.added_count,
                tampered_or_rejected
            )
        };
        self.last_sync_report = Some(UiSyncActivityReport {
            channel: "WebDAV 异步留存通道".to_string(),
            summary_title: status_title,
            added_events: import_summary.added_count,
            duplicate_events: import_summary.duplicate_count,
            rejected_or_tampered: tampered_or_rejected,
            uploaded_objects: uploaded_hashes.len(),
            failed_uploads: failed_hashes.len(),
            package_byte_len: 0,
            package_digest: None,
            exported_tripdelta_json: None,
            exported_compact_code: None,
        });
        Ok(())
    }

    pub fn propose_settlement(
        &mut self,
        actor_id: &str,
        snapshot_id: &str,
        mode: SettlementMode,
        settlement_currency: Option<&str>,
    ) -> CoreResult<SignedEvent> {
        let (device_id, keypair) = self.member_keys.get(actor_id).cloned().ok_or_else(|| {
            CoreError::NotFound(format!("actor '{actor_id}' has no local signing key"))
        })?;

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
            &self.default_fx_rates,
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
            fx_rates: self.default_fx_rates.clone(),
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

        let (seq, prev_ev) = self.repo.next_device_sequence(&self.group_id, &device_id)?;
        let unsigned = UnsignedEvent {
            schema_version: CURRENT_SCHEMA_VERSION,
            group_id: self.group_id.clone(),
            author_member_id: actor_id.to_string(),
            author_public_key: keypair.public_key_b64(),
            device_id,
            sequence: seq,
            previous_event_id: prev_ev,
            policy_version_id: proj.active_policy_event_id,
            body: EventBody::SettlementPropose(snap),
        };
        let signed = SignedEvent::sign_new(unsigned, &keypair)?;
        self.repo.append_signed_event(&signed, Some(&self.cipher))?;
        Ok(signed)
    }

    pub fn approve_settlement(
        &mut self,
        actor_id: &str,
        snapshot_id: &str,
    ) -> CoreResult<SignedEvent> {
        let (device_id, keypair) = self.member_keys.get(actor_id).cloned().ok_or_else(|| {
            CoreError::NotFound(format!("actor '{actor_id}' has no local signing key"))
        })?;

        let proj = self.repo.project_group(&self.group_id)?;
        proj.ensure_formal_settlement_ready()?;
        proj.ensure_snapshot_current(snapshot_id)?;
        let snap_item = proj
            .snapshots
            .get(snapshot_id)
            .ok_or_else(|| CoreError::NotFound(format!("snapshot '{snapshot_id}' not found")))?;

        let payload = SettlementApprovePayload {
            snapshot_id: snapshot_id.to_string(),
            snapshot_digest: snap_item.snapshot.snapshot_digest.clone(),
            approver_participant_id: actor_id.to_string(),
        };
        let (seq, prev_ev) = self.repo.next_device_sequence(&self.group_id, &device_id)?;
        let unsigned = UnsignedEvent {
            schema_version: CURRENT_SCHEMA_VERSION,
            group_id: self.group_id.clone(),
            author_member_id: actor_id.to_string(),
            author_public_key: keypair.public_key_b64(),
            device_id,
            sequence: seq,
            previous_event_id: prev_ev,
            policy_version_id: proj.active_policy_event_id,
            body: EventBody::SettlementApprove(payload),
        };
        let signed = SignedEvent::sign_new(unsigned, &keypair)?;
        self.repo.append_signed_event(&signed, Some(&self.cipher))?;
        Ok(signed)
    }

    pub fn commit_settlement(
        &mut self,
        actor_id: &str,
        snapshot_id: &str,
    ) -> CoreResult<SignedEvent> {
        let (device_id, keypair) = self.member_keys.get(actor_id).cloned().ok_or_else(|| {
            CoreError::NotFound(format!("actor '{actor_id}' has no local signing key"))
        })?;

        let proj = self.repo.project_group(&self.group_id)?;
        proj.ensure_formal_settlement_ready()?;
        proj.ensure_snapshot_current(snapshot_id)?;
        let snap_item = proj
            .snapshots
            .get(snapshot_id)
            .ok_or_else(|| CoreError::NotFound(format!("snapshot '{snapshot_id}' not found")))?;

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
        let (seq, prev_ev) = self.repo.next_device_sequence(&self.group_id, &device_id)?;
        let unsigned = UnsignedEvent {
            schema_version: CURRENT_SCHEMA_VERSION,
            group_id: self.group_id.clone(),
            author_member_id: actor_id.to_string(),
            author_public_key: keypair.public_key_b64(),
            device_id,
            sequence: seq,
            previous_event_id: prev_ev,
            policy_version_id: proj.active_policy_event_id,
            body: EventBody::SettlementCommit(payload),
        };
        let signed = SignedEvent::sign_new(unsigned, &keypair)?;
        self.repo.append_signed_event(&signed, Some(&self.cipher))?;
        Ok(signed)
    }

    pub fn build_ui_snapshot(&self) -> CoreResult<UiWorkspaceSnapshot> {
        let all_events = self.repo.list_events(&self.group_id)?;
        let proj = build_projection(&self.group_id, &all_events)?;
        let open_debts = proj.open_pair_debts_with_history(&all_events)?;

        let mut event_lookup: BTreeMap<String, &SignedEvent> = BTreeMap::new();
        for ev in &all_events {
            event_lookup.insert(ev.event_id.clone(), ev);
        }

        let mut expenses = Vec::new();
        for (exp_id, item) in &proj.expenses {
            let mut history = Vec::new();
            for rev_id in &item.revision_history_event_ids {
                if let Some(ev) = event_lookup.get(rev_id) {
                    if let EventBody::ExpenseUpsert(payload) = &ev.unsigned.body {
                        history.push(UiRevisionEntry {
                            event_id: ev.event_id.clone(),
                            author_member_id: ev.unsigned.author_member_id.clone(),
                            device_id: ev.unsigned.device_id.clone(),
                            sequence: ev.unsigned.sequence,
                            payload: payload.clone(),
                        });
                    }
                }
            }
            let mut conflict_branches = Vec::new();
            for leaf_id in &item.conflict_leaf_event_ids {
                if let Some(ev) = event_lookup.get(leaf_id) {
                    if let EventBody::ExpenseUpsert(payload) = &ev.unsigned.body {
                        conflict_branches.push(UiRevisionEntry {
                            event_id: ev.event_id.clone(),
                            author_member_id: ev.unsigned.author_member_id.clone(),
                            device_id: ev.unsigned.device_id.clone(),
                            sequence: ev.unsigned.sequence,
                            payload: payload.clone(),
                        });
                    }
                }
            }

            expenses.push(UiExpenseView {
                expense_id: exp_id.clone(),
                creator_member_id: item.creator_member_id.clone(),
                has_conflict: item.has_conflict,
                is_settled_in_prior_commit: proj.settled_expense_revisions.contains_key(exp_id),
                active_revision_event_id: item.active_revision_event_id.clone(),
                active_revision: item.active_revision.clone(),
                conflict_branches,
                history,
            });
        }

        let all_participants: BTreeSet<String> =
            proj.active_policy.participants.keys().cloned().collect();
        let settlement_currency = self.repo.get_meta("settlement_currency")?
            .unwrap_or_else(default_settlement_currency);
        let mut settlement_previews = BTreeMap::new();
        for (key, mode, target_curr) in [
            ("ByCurrencyPairwise", SettlementMode::ByCurrencyPairwise, None),
            (
                "ByCurrencyMinTransfers",
                SettlementMode::ByCurrencyMinTransfers,
                None,
            ),
            (
                "MergedCurrencyPairwise",
                SettlementMode::MergedCurrencyPairwise,
                Some(settlement_currency.as_str()),
            ),
            (
                "MergedCurrencyMinTransfers",
                SettlementMode::MergedCurrencyMinTransfers,
                Some(settlement_currency.as_str()),
            ),
        ] {
            if let Ok(res) = compute_settlement_from_pair_debts(
                &all_participants,
                &proj.active_policy.currencies,
                &open_debts,
                mode,
                target_curr,
                &self.default_fx_rates,
            ) {
                settlement_previews.insert(
                    key.to_string(),
                    UiSettlementPreview {
                        mode: res.mode,
                        settlement_currency: res.settlement_currency,
                        net_balances_by_currency: res.net_balances_by_currency,
                        transfers: res.transfers,
                        optimality: res.optimality,
                    },
                );
            }
        }

        let opaque_dir = opaque_group_directory_id(&self.group_id);
        let pending_raw = self.repo.pending_webdav_uploads(&self.group_id)?;
        let pending_uploads = pending_raw.len();
        let pending_upload_items: Vec<UiWebDavPendingObject> = pending_raw
            .into_iter()
            .map(|(h, _, ct)| UiWebDavPendingObject {
                object_hash: h,
                ciphertext_b64: URL_SAFE_NO_PAD.encode(&ct),
            })
            .collect();
        let remote_objects = self
            .webdav_remote
            .list_encrypted_objects(&opaque_dir)
            .map(|v| v.len())
            .unwrap_or(0);

        let mut discovered_peers = Vec::new();
        if !self.lan_ap_isolation {
            for (idx, p) in proj.active_policy.participants.values().enumerate() {
                if p.participant_id == self.active_actor_id || p.bound_public_key.is_none() {
                    continue;
                }
                let dev_id = format!("dev_{}", p.participant_id.to_lowercase());
                let cursor = proj.device_cursors.get(&dev_id);
                discovered_peers.push(UiLanPeerItem {
                    member_id: p.participant_id.clone(),
                    display_name: p.display_name_or_id(),
                    device_id: dev_id,
                    endpoint_addr: format!("192.168.43.{}:9443 (QUIC/mDNS)", 101 + idx),
                    contiguous_seq: cursor.map(|c| c.contiguous_seq).unwrap_or(0),
                    max_seen_seq: cursor.map(|c| c.max_seen_seq).unwrap_or(0),
                    missing_seqs: cursor.map(|c| c.missing_seqs.clone()).unwrap_or_default(),
                });
            }
        }

        let (solved, total) = self.optical_assembler.progress();
        let active_pkg_id = self
            .optical_assembler
            .active_package_id()
            .map(|s| s.to_string());

        let conflict_count = expenses.iter().filter(|e| e.has_conflict).count();
        let pending_repayment_count = proj
            .repayments
            .values()
            .filter(|r| r.status == RepaymentStatus::DeclaredByPayer)
            .count();

        let mut merged_categories: BTreeMap<String, UiExpenseCategory> = BTreeMap::new();
        for cat in &self.custom_categories {
            merged_categories.insert(cat.name.clone(), cat.clone());
        }
        for cat in &proj.custom_categories {
            merged_categories.insert(
                cat.name.clone(),
                UiExpenseCategory {
                    id: cat.id.clone(),
                    icon: cat.icon.clone(),
                    name: cat.name.clone(),
                    is_custom: true,
                },
            );
        }

        let formal_settlement_blocker = proj.ensure_formal_settlement_ready().err().map(|e| e.to_string());
        Ok(UiWorkspaceSnapshot {
            group_id: self.group_id.clone(),
            group_name: proj.active_policy.group_name.clone(),
            active_actor_id: self.active_actor_id.clone(),
            active_policy_event_id: proj.active_policy_event_id.clone(),
            participants: proj.active_policy.participants.values().cloned().collect(),
            default_fx_rates: self.default_fx_rates.clone(),
            custom_categories: merged_categories.into_values().collect(),
            policy: proj.active_policy,
            expenses,
            repayments: proj.repayments.values().cloned().collect(),
            active_obligations: proj.active_obligations.values().cloned().collect(),
            snapshots: proj.snapshots.values().cloned().collect(),
            settlement_previews,
            settlement_currency,
            formal_settlement_blocker,
            webdav_status: UiWebDavStatus {
                enabled: self.webdav_enabled,
                endpoint_url: self.webdav_endpoint.clone(),
                username: self.webdav_username.clone(),
                opaque_group_dir: opaque_dir,
                simulate_unreachable: self.webdav_remote.fail_writes,
                pending_upload_count: pending_uploads,
                remote_object_count: remote_objects,
                pending_uploads: pending_upload_items,
            },
            lan_status: UiLanSyncStatus {
                multicast_lock_active: self.lan_multicast_lock,
                ap_isolation_detected: self.lan_ap_isolation,
                local_endpoint_ticket: format!(
                    "sbill-lan://{}/{}@192.168.43.100:9443",
                    self.group_id, self.active_actor_id
                ),
                discovered_peers,
            },
            optical_session: UiOpticalSessionView {
                outgoing_frames: self.optical_outgoing_frames.clone(),
                recommended_fps: if self.optical_slow_mode { 2 } else { 5 },
                slow_mode: self.optical_slow_mode,
                receiver_active_package_id: active_pkg_id,
                receiver_solved_slices: solved,
                receiver_total_slices: total,
                receiver_complete: self.optical_last_completed,
            },
            last_sync_report: self.last_sync_report.clone(),
            conflict_count,
            pending_repayment_count,
            pending_reauth_count: proj.pending_reauth_events.len(),
            total_event_count: all_events.len(),
        })
    }
}

trait ParticipantDisplayExt {
    fn display_name_or_id(&self) -> String;
}

impl ParticipantDisplayExt for ParticipantProfile {
    fn display_name_or_id(&self) -> String {
        if self.display_name.is_empty() {
            self.participant_id.clone()
        } else {
            self.display_name.clone()
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(tag = "op", content = "args")]
pub enum FfiCommand {
    InitOrGetSnapshot,
    OpenPersistentWorkspace {
        db_path: String,
    },
    ResetDemoWorkspace,
    SwitchActor {
        actor_id: String,
    },
    SetSettlementCurrency { currency: String },
    SetFxRate {
        base_currency: String,
        quote_currency: String,
        numerator: i64,
        denominator: i64,
    },
    AddParticipant {
        actor_id: String,
        participant_id: String,
        display_name: String,
        role: Role,
        bind_device_key: bool,
    },
    UpsertExpense {
        actor_id: String,
        expense_id: String,
        parent_revision_event_ids: Vec<String>,
        currency: String,
        total_minor: i64,
        payers: Vec<PayerContribution>,
        split_rule: SplitRule,
        title: String,
        note: String,
        revision_reason: String,
        voided: bool,
        #[serde(default)]
        details: Option<crate::domain::ExpenseDetails>,
    },
    SimulateConcurrentConflict {
        expense_id: String,
    },
    DeclareRepayment {
        actor_id: String,
        payment_id: String,
        payer_id: String,
        payee_id: String,
        currency: String,
        amount_minor: i64,
        target_obligation_id: Option<String>,
        note: String,
    },
    ConfirmRepayment {
        actor_id: String,
        payment_id: String,
        declare_event_id: String,
        overpayment_policy: Option<String>,
    },
    DisputeRepayment {
        actor_id: String,
        payment_id: String,
        declare_event_id: String,
        reason: String,
    },
    MapLateRepayment {
        actor_id: String,
        payment_id: String,
        target_obligation_id: String,
        note: String,
    },
    ExportIdentityBackup {
        passphrase: String,
    },
    RestoreIdentityBackup {
        backup_json: String,
        passphrase: String,
    },
    ApplyWebDavHttpSync {
        uploaded_hashes: Vec<String>,
        failed_hashes: Vec<String>,
        downloaded_objects: Vec<(String, String)>,
    },
    ProposeSettlement {
        actor_id: String,
        snapshot_id: String,
        mode: SettlementMode,
        settlement_currency: Option<String>,
    },
    ApproveSettlement {
        actor_id: String,
        snapshot_id: String,
    },
    CommitSettlement {
        actor_id: String,
        snapshot_id: String,
    },
    ExportTripDelta,
    ImportTripDelta {
        payload: String,
    },
    SimulatePeerTripDelta {
        auto_import: bool,
    },
    ConfigureWebDav {
        endpoint_url: String,
        username: String,
        simulate_unreachable: bool,
    },
    SyncWebDavNow,
    SimulateRemoteWebDavIncoming {
        inject_tampered: bool,
    },
    ConfigureLanDiscovery {
        ap_isolation_detected: bool,
    },
    SyncLanWithPeer {
        peer_member_id: String,
        simulate_gap_fill: bool,
    },
    GenerateOpticalFrames {
        slice_byte_len: usize,
        parity_frames: usize,
        slow_mode: bool,
    },
    IngestOpticalFrame {
        frame_json: String,
    },
    SimulateOpticalAirgapTransfer {
        drop_first_two_frames: bool,
    },
    AddCustomCategory {
        id: String,
        icon: String,
        name: String,
    },
    RemoveCustomCategory {
        id: String,
    },
}

#[derive(Debug, Serialize, Deserialize)]
pub struct FfiResponse {
    pub ok: bool,
    pub error: Option<String>,
    pub snapshot: Option<UiWorkspaceSnapshot>,
}

static GLOBAL_SESSION: OnceLock<Mutex<WorkspaceSession>> = OnceLock::new();

pub fn dispatch_ffi_json_on_session(
    session: &mut WorkspaceSession,
    request_json: &str,
) -> String {
    let parsed: Result<FfiCommand, _> = serde_json::from_str(request_json);
    let resp = match parsed {
        Err(e) => FfiResponse {
            ok: false,
            error: Some(format!("invalid FFI command JSON: {e}")),
            snapshot: None,
        },
        Ok(cmd) => {
            let step = (|| -> CoreResult<UiWorkspaceSnapshot> {
                match cmd {
                    FfiCommand::InitOrGetSnapshot => {}
                    FfiCommand::OpenPersistentWorkspace { db_path } => {
                        let trimmed = db_path.trim();
                        if !trimmed.is_empty()
                            && session.db_path.as_deref() != Some(trimmed)
                        {
                            *session = WorkspaceSession::open_or_init_persistent(trimmed)?;
                        }
                    }
                    FfiCommand::ResetDemoWorkspace => {
                        if let Some(existing_path) = session.db_path.clone() {
                            session.repo.clear_all_tables()?;
                            let reopened = LedgerRepository::open_file(&existing_path)?;
                            *session = WorkspaceSession::seed_into_repo(
                                reopened,
                                Some(existing_path),
                            )?;
                        } else {
                            *session = WorkspaceSession::new_with_sample_trip()?;
                        }
                    }
                    FfiCommand::SwitchActor { actor_id } => {
                        session.active_actor_id = actor_id;
                    }
                    FfiCommand::SetSettlementCurrency { currency } => {
                        if !session.repo.project_group(&session.group_id)?.active_policy.currencies.contains_key(&currency) {
                            return Err(CoreError::FinancialValidation("未知结算币种".into()));
                        }
                        session.repo.set_meta("settlement_currency", &currency)?;
                    }
                    FfiCommand::SetFxRate {
                        base_currency,
                        quote_currency,
                        numerator,
                        denominator,
                    } => {
                        session.set_fx_rate(
                            &base_currency,
                            &quote_currency,
                            numerator,
                            denominator,
                        )?;
                    }
                    FfiCommand::AddParticipant {
                        actor_id,
                        participant_id,
                        display_name,
                        role,
                        bind_device_key,
                    } => {
                        session.add_participant(
                            &actor_id,
                            &participant_id,
                            &display_name,
                            role,
                            bind_device_key,
                        )?;
                    }
                    FfiCommand::UpsertExpense {
                        actor_id,
                        expense_id,
                        parent_revision_event_ids,
                        currency,
                        total_minor,
                        payers,
                        split_rule,
                        title,
                        note,
                        revision_reason,
                        voided,
                        details,
                    } => {
                        session.upsert_expense_with_details(
                            &actor_id,
                            &expense_id,
                            parent_revision_event_ids,
                            &currency,
                            total_minor,
                            payers,
                            split_rule,
                            &title,
                            &note,
                            &revision_reason,
                            voided,
                            details,
                        )?;
                    }
                    FfiCommand::SimulateConcurrentConflict { expense_id } => {
                        let snap = session.build_ui_snapshot()?;
                        let exp = snap
                            .expenses
                            .iter()
                            .find(|e| e.expense_id == expense_id)
                            .ok_or_else(|| {
                                CoreError::NotFound(format!("expense '{expense_id}' not found"))
                            })?;
                        let base_rev_id = exp.active_revision_event_id.clone().ok_or_else(|| {
                            CoreError::Conflict(format!(
                                "expense '{expense_id}' already in conflict"
                            ))
                        })?;
                        let base_rev = exp.active_revision.clone().unwrap();

                        let mut payers_a = base_rev.payers.clone();
                        payers_a[0].amount_minor += 5_000;
                        session.upsert_expense(
                            &exp.creator_member_id,
                            &expense_id,
                            vec![base_rev_id.clone()],
                            &base_rev.currency,
                            base_rev.total_minor + 5_000,
                            payers_a,
                            base_rev.split_rule.clone(),
                            &format!("{} (创建人离线改)", base_rev.title),
                            &base_rev.note,
                            "创建人离线补记小费 +50",
                            false,
                        )?;

                        let mut payers_b = base_rev.payers.clone();
                        payers_b[0].amount_minor += 12_000;
                        session.upsert_expense(
                            "B",
                            &expense_id,
                            vec![base_rev_id],
                            &base_rev.currency,
                            base_rev.total_minor + 12_000,
                            payers_b,
                            base_rev.split_rule,
                            &format!("{} (管理员离线改)", base_rev.title),
                            &base_rev.note,
                            "管理员白露离线核对账单 +120",
                            false,
                        )?;
                    }
                    FfiCommand::DeclareRepayment {
                        actor_id,
                        payment_id,
                        payer_id,
                        payee_id,
                        currency,
                        amount_minor,
                        target_obligation_id,
                        note,
                    } => {
                        session.declare_repayment(
                            &actor_id,
                            &payment_id,
                            &payer_id,
                            &payee_id,
                            &currency,
                            amount_minor,
                            target_obligation_id,
                            &note,
                        )?;
                    }
                    FfiCommand::ConfirmRepayment {
                        actor_id,
                        payment_id,
                        declare_event_id,
                        overpayment_policy,
                    } => {
                        session.confirm_repayment(
                            &actor_id,
                            &payment_id,
                            &declare_event_id,
                            overpayment_policy,
                        )?;
                    }
                    FfiCommand::DisputeRepayment {
                        actor_id,
                        payment_id,
                        declare_event_id,
                        reason,
                    } => {
                        session.dispute_repayment(
                            &actor_id,
                            &payment_id,
                            &declare_event_id,
                            &reason,
                        )?;
                    }
                    FfiCommand::MapLateRepayment {
                        actor_id,
                        payment_id,
                        target_obligation_id,
                        note,
                    } => {
                        session.map_late_repayment(
                            &actor_id,
                            &payment_id,
                            &target_obligation_id,
                            &note,
                        )?;
                    }
                    FfiCommand::ExportIdentityBackup { passphrase } => {
                        session.export_identity_backup(&passphrase)?;
                    }
                    FfiCommand::RestoreIdentityBackup {
                        backup_json,
                        passphrase,
                    } => {
                        session.restore_identity_backup(&backup_json, &passphrase)?;
                    }
                    FfiCommand::ApplyWebDavHttpSync {
                        uploaded_hashes,
                        failed_hashes,
                        downloaded_objects,
                    } => {
                        session.apply_webdav_http_sync(
                            uploaded_hashes,
                            failed_hashes,
                            downloaded_objects,
                        )?;
                    }
                    FfiCommand::ProposeSettlement {
                        actor_id,
                        snapshot_id,
                        mode,
                        settlement_currency,
                    } => {
                        session.propose_settlement(
                            &actor_id,
                            &snapshot_id,
                            mode,
                            settlement_currency.as_deref(),
                        )?;
                    }
                    FfiCommand::ApproveSettlement {
                        actor_id,
                        snapshot_id,
                    } => {
                        session.approve_settlement(&actor_id, &snapshot_id)?;
                    }
                    FfiCommand::CommitSettlement {
                        actor_id,
                        snapshot_id,
                    } => {
                        session.commit_settlement(&actor_id, &snapshot_id)?;
                    }
                    FfiCommand::ExportTripDelta => {
                        session.export_tripdelta()?;
                    }
                    FfiCommand::ImportTripDelta { payload } => {
                        session.import_tripdelta_payload(&payload)?;
                    }
                    FfiCommand::SimulatePeerTripDelta { auto_import } => {
                        session.simulate_peer_incoming_tripdelta(auto_import)?;
                    }
                    FfiCommand::ConfigureWebDav {
                        endpoint_url,
                        username,
                        simulate_unreachable,
                    } => {
                        session.configure_webdav(&endpoint_url, &username, simulate_unreachable)?;
                    }
                    FfiCommand::SyncWebDavNow => {
                        session.sync_webdav_now()?;
                    }
                    FfiCommand::SimulateRemoteWebDavIncoming { inject_tampered } => {
                        session.simulate_remote_webdav_incoming(inject_tampered)?;
                    }
                    FfiCommand::ConfigureLanDiscovery {
                        ap_isolation_detected,
                    } => {
                        session.configure_lan_discovery(ap_isolation_detected)?;
                    }
                    FfiCommand::SyncLanWithPeer {
                        peer_member_id,
                        simulate_gap_fill,
                    } => {
                        session
                            .sync_lan_with_discovered_peer(&peer_member_id, simulate_gap_fill)?;
                    }
                    FfiCommand::GenerateOpticalFrames {
                        slice_byte_len,
                        parity_frames,
                        slow_mode,
                    } => {
                        session.generate_optical_frames(
                            slice_byte_len,
                            parity_frames,
                            slow_mode,
                        )?;
                    }
                    FfiCommand::IngestOpticalFrame { frame_json } => {
                        session.ingest_optical_frame_json(&frame_json)?;
                    }
                    FfiCommand::SimulateOpticalAirgapTransfer {
                        drop_first_two_frames,
                    } => {
                        session.simulate_optical_airgap_transfer(drop_first_two_frames)?;
                    }
                    FfiCommand::AddCustomCategory { id, icon, name } => {
                        let clean_name = name.trim().to_string();
                        let clean_icon = if icon.trim().is_empty() {
                            "🏷️".to_string()
                        } else {
                            icon.trim().to_string()
                        };
                        if clean_name.is_empty() {
                            return Err(CoreError::FinancialValidation(
                                "自定义分类名称不能为空".to_string(),
                            ));
                        }
                        let actor_id = session.active_actor_id.clone();
                        session.upsert_custom_category(
                            &actor_id,
                            &id,
                            &clean_icon,
                            &clean_name,
                            false,
                        )?;
                    }
                    FfiCommand::RemoveCustomCategory { id } => {
                        session.custom_categories.retain(|c| c.id != id);
                        let actor_id = session.active_actor_id.clone();
                        session.upsert_custom_category(&actor_id, &id, "", "", true)?;
                    }
                }
                session.persist_session_metadata()?;
                session.build_ui_snapshot()
            })();

            match step {
                Ok(snapshot) => FfiResponse {
                    ok: true,
                    error: None,
                    snapshot: Some(snapshot),
                },
                Err(err) => FfiResponse {
                    ok: false,
                    error: Some(err.to_string()),
                    snapshot: None,
                },
            }
        }
    };

    serde_json::to_string(&resp).unwrap_or_else(|e| {
        format!(r#"{{"ok":false,"error":"serialization error: {e}","snapshot":null}}"#)
    })
}

pub fn dispatch_ffi_json(request_json: &str) -> String {
    if serde_json::from_str::<serde_json::Value>(request_json)
        .ok().and_then(|v| v["op"].as_str().map(|s| s.strip_prefix("App").and_then(|suffix| suffix.chars().next())
                    .is_some_and(|c| c.is_ascii_uppercase()))) == Some(true) {
        return crate::workspace::dispatch_app_json(request_json);
    }
    let mutex = GLOBAL_SESSION.get_or_init(|| {
        Mutex::new(
            WorkspaceSession::new_with_sample_trip()
                .expect("sample workspace initialization must succeed"),
        )
    });
    match mutex.lock() {
        Ok(mut guard) => dispatch_ffi_json_on_session(&mut guard, request_json),
        Err(_) => r#"{"ok":false,"error":"workspace session mutex poisoned","snapshot":null}"#
            .to_string(),
    }
}

/// C-ABI entrypoint called by Dart `Isolate.run` via `dart:ffi`.
/// Caller must free the returned string using `sbill_core_free_string`.
#[no_mangle]
pub unsafe extern "C" fn sbill_core_invoke_json(request_ptr: *const c_char) -> *mut c_char {
    if request_ptr.is_null() {
        let err =
            CString::new(r#"{"ok":false,"error":"null request_ptr","snapshot":null}"#).unwrap();
        return err.into_raw();
    }
    let req_str = match CStr::from_ptr(request_ptr).to_str() {
        Ok(s) => s,
        Err(_) => {
            let err = CString::new(
                r#"{"ok":false,"error":"invalid UTF-8 in request_ptr","snapshot":null}"#,
            )
            .unwrap();
            return err.into_raw();
        }
    };
    let response_json = dispatch_ffi_json(req_str);
    CString::new(response_json)
        .unwrap_or_else(|_| {
            CString::new(r#"{"ok":false,"error":"interior nul byte","snapshot":null}"#).unwrap()
        })
        .into_raw()
}

/// Frees a C string previously returned by `sbill_core_invoke_json`.
#[no_mangle]
pub unsafe extern "C" fn sbill_core_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        let _ = CString::from_raw(ptr);
    }
}

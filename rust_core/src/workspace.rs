//! Installation identity and a catalog of isolated, disk-backed trip ledgers.
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use rand::{rngs::OsRng, RngCore};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
};

use crate::{
    crypto::{
        blake3_hash_b64, canonical_json_bytes, verify_ed25519_signature, DeviceKeypair, GroupCipher,
    },
    domain::*,
    error::{CoreError, CoreResult},
    ffi::{dispatch_ffi_json_on_session, FfiResponse, UiWorkspaceSnapshot, WorkspaceSession},
    storage::{build_projection, LedgerRepository},
};

const MAX_TRANSFER_BYTES: usize = 20 * 1024 * 1024;
const JOIN_AAD: &[u8] = b"sbill:join:v1";

fn invalid(message: &str) -> CoreError {
    CoreError::Policy(message.to_string())
}
fn random_id(prefix: &str) -> String {
    let mut bytes = [0; 16];
    OsRng.fill_bytes(&mut bytes);
    format!("{prefix}_{}", hex::encode(bytes))
}
fn name(raw: &str) -> CoreResult<String> {
    let value = raw.trim();
    if value.is_empty() || value.chars().count() > 80 {
        return Err(invalid("名称须为 1–80 个字符"));
    }
    Ok(value.to_string())
}
fn encode<T: Serialize>(prefix: &str, value: &T) -> CoreResult<String> {
    Ok(format!(
        "{prefix}{}",
        URL_SAFE_NO_PAD.encode(serde_json::to_vec(value)?)
    ))
}
fn decode<T: for<'a> Deserialize<'a>>(prefix: &str, raw: &str) -> CoreResult<T> {
    if raw.len() > MAX_TRANSFER_BYTES {
        return Err(invalid("同步内容超过 20 MiB"));
    }
    let body = raw
        .trim()
        .strip_prefix(prefix)
        .ok_or_else(|| invalid("同步码类型不匹配"))?;
    let bytes = URL_SAFE_NO_PAD
        .decode(body)
        .map_err(|_| invalid("同步码编码无效"))?;
    Ok(serde_json::from_slice(&bytes)?)
}

#[derive(Clone, Serialize, Deserialize)]
pub struct LedgerEntry {
    pub group_id: String,
    pub group_name: String,
    pub member_id: String,
    pub legacy: bool,
}
#[derive(Default, Clone, Serialize, Deserialize)]
struct Catalog {
    ledgers: Vec<LedgerEntry>,
    active_group_id: Option<String>,
}
#[derive(Serialize)]
pub struct AppSnapshot {
    pub ledgers: Vec<LedgerEntry>,
    pub active_ledger: Option<UiWorkspaceSnapshot>,
    pub identity_fingerprint: String,
    pub transfer_code: Option<String>,
    pub access_key: Option<String>,
    pub claim_preview: Option<Value>,
}
#[derive(Clone, Serialize, Deserialize)]
struct ClaimBody {
    version: u32,
    group_id: String,
    participant_id: String,
    display_name: String,
    public_key: String,
    device_id: String,
    nonce: String,
}
#[derive(Serialize, Deserialize)]
struct ClaimRequest {
    body: ClaimBody,
    signature: String,
}
#[derive(Serialize, Deserialize)]
struct Welcome {
    version: u32,
    group_id: String,
    member_id: String,
    public_key: String,
    cipher_b64: String,
    events: Vec<SignedEvent>,
}

#[derive(Deserialize)]
#[serde(tag = "op", content = "args")]
pub enum AppCommand {
    AppOpen {
        db_path: String,
    },
    AppGet,
    AppCreateLedger {
        group_name: String,
        display_name: String,
        companions: Vec<String>,
    },
    AppSelectLedger {
        group_id: String,
    },
    AppShowLedgers,
    AppAddParticipant {
        group_id: String,
        display_name: String,
        role: Role,
    },
    AppUpdateParticipant {
        group_id: String,
        participant_id: String,
        display_name: String,
        role: Role,
        active: bool,
    },
    AppInspectClaim {
        group_id: String,
        request: String,
    },
    AppCreateClaim {
        group_id: String,
        participant_id: String,
        display_name: String,
    },
    AppApproveClaim {
        group_id: String,
        request: String,
        participant_id: String,
    },
    AppJoinLedger {
        welcome: String,
        access_key: String,
    },
    AppLedgerCommand {
        group_id: String,
        command: Value,
    },
}

pub struct AppWorkspace {
    root: PathBuf,
    catalog_repo: LedgerRepository,
    catalog: Catalog,
    device_id: String,
    keypair: DeviceKeypair,
    session: Option<WorkspaceSession>,
}
impl AppWorkspace {
    pub fn open(db_path: impl AsRef<Path>) -> CoreResult<Self> {
        let old_path = db_path.as_ref();
        let root = old_path
            .parent()
            .ok_or_else(|| invalid("无效的本机数据目录"))?
            .to_path_buf();
        std::fs::create_dir_all(&root).map_err(|e| invalid(&format!("无法建立数据目录：{e}")))?;
        let catalog_path = old_path.with_extension("catalog.sqlite3");
        let catalog_repo = LedgerRepository::open_file(catalog_path)?;
        let mut catalog: Catalog = match catalog_repo.get_meta("catalog_v1")? {
            Some(raw) => serde_json::from_str(&raw)?,
            None => Catalog::default(),
        };
        let identity = catalog_repo.load_member_keys()?.remove("installation");
        let (device_id, keypair) = match identity {
            Some((id, secret)) => (id, DeviceKeypair::from_secret_bytes(&secret)),
            None if !catalog.ledgers.is_empty() => {
                return Err(invalid("本机身份密钥丢失，不能生成替代身份打开已有账本"))
            }
            None => {
                let id = random_id("device");
                let key = DeviceKeypair::generate();
                catalog_repo.save_member_key("installation", &id, &key.secret_bytes())?;
                (id, key)
            }
        };
        // The old database is never reseeded or cleared during an upgrade.
        if catalog_repo.get_meta("legacy_scan_done")?.is_none() {
            if old_path.exists() {
                let repo = LedgerRepository::open_file(old_path)?;
                if repo.total_event_count()? > 0 {
                    let group_id = repo
                        .get_meta("group_id")?
                        .ok_or_else(|| invalid("旧账本缺少身份信息，请保留文件进行恢复"))?;
                    let proj = repo.project_group(&group_id)?;
                    let member_id = repo
                        .get_meta("active_actor_id")?
                        .ok_or_else(|| invalid("旧账本缺少本机成员信息"))?;
                    if !catalog.ledgers.iter().any(|e| e.group_id == group_id) {
                        catalog.ledgers.push(LedgerEntry {
                            group_id: group_id.clone(),
                            group_name: proj.active_policy.group_name,
                            member_id,
                            legacy: true,
                        });
                    }
                    catalog.active_group_id = Some(group_id);
                    catalog_repo.set_meta("legacy_path", &old_path.to_string_lossy())?;
                }
            }
            catalog_repo.set_meta("catalog_v1", &serde_json::to_string(&catalog)?)?;
            catalog_repo.set_meta("legacy_scan_done", "true")?;
        }
        let mut app = Self {
            root,
            catalog_repo,
            catalog,
            device_id,
            keypair,
            session: None,
        };
        if let Some(id) = app.catalog.active_group_id.clone() {
            app.select(&id)?;
        }
        Ok(app)
    }
    fn ledger_path(&self, id: &str) -> PathBuf {
        // Hash even imported IDs: no untrusted path segments reach the filesystem.
        self.root.join(format!(
            "ledger_{}.sqlite3",
            hex::encode(blake3::hash(id.as_bytes()).as_bytes())
        ))
    }
    fn save_catalog(&self) -> CoreResult<()> {
        self.catalog_repo
            .set_meta("catalog_v1", &serde_json::to_string(&self.catalog)?)
    }
    fn select(&mut self, id: &str) -> CoreResult<()> {
        let entry = self
            .catalog
            .ledgers
            .iter()
            .find(|e| e.group_id == id)
            .ok_or_else(|| invalid("找不到该账本"))?
            .clone();
        if let Some(current) = &self.session {
            current.persist_session_metadata()?;
        }
        let path = if entry.legacy {
            PathBuf::from(
                self.catalog_repo
                    .get_meta("legacy_path")?
                    .ok_or_else(|| invalid("旧账本路径丢失"))?,
            )
        } else {
            self.ledger_path(id)
        };
        if !path.exists() {
            return Err(invalid("账本文件丢失，未创建替代示例数据"));
        }
        let repo = LedgerRepository::open_file(&path)?;
        if repo.total_event_count()? == 0
            || repo.get_meta("cipher_b64")?.is_none()
            || repo.get_meta("group_id")?.as_deref() != Some(id)
        {
            return Err(invalid("账本数据不完整，请保留原文件进行恢复"));
        }
        drop(repo);
        let mut session = WorkspaceSession::open_or_init_persistent(&path)?;
        session.active_actor_id = entry.member_id.clone();
        if !entry.legacy {
            session.member_keys.clear();
            session.member_keys.insert(
                entry.member_id.clone(),
                (self.device_id.clone(), self.keypair.clone()),
            );
        } else {
            session
                .member_keys
                .retain(|member, _| member == &entry.member_id);
        }
        let proj = session.repo.project_group(id)?;
        let key = session
            .member_keys
            .get(&entry.member_id)
            .ok_or_else(|| invalid("本机签名身份丢失"))?;
        if proj
            .active_policy
            .participants
            .get(&entry.member_id)
            .and_then(|p| p.bound_public_key.as_deref())
            != Some(key.1.public_key_b64().as_str())
        {
            return Err(invalid("本机身份与账本成员绑定不一致"));
        }
        self.catalog.active_group_id = Some(id.to_string());
        self.save_catalog()?;
        self.session = Some(session);
        Ok(())
    }
    fn session(&mut self) -> CoreResult<&mut WorkspaceSession> {
        self.session
            .as_mut()
            .ok_or_else(|| invalid("请先选择一个出行账本"))
    }
    fn require_group(&mut self, id: &str) -> CoreResult<()> {
        if self.session()?.group_id != id {
            return Err(invalid("账本已切换，请重新打开页面"));
        }
        if self
            .catalog
            .ledgers
            .iter()
            .any(|e| e.group_id == id && e.legacy)
        {
            return Err(invalid(
                "旧版演示身份账本仅保留原账目，暂不开放新增伙伴或认领；请新建账本开展协作",
            ));
        }
        Ok(())
    }
    fn create(
        &mut self,
        group_name: &str,
        display_name: &str,
        companions: Vec<String>,
    ) -> CoreResult<()> {
        let group_name = name(group_name)?;
        let display_name = name(display_name)?;
        if companions.len() > 19 {
            return Err(invalid("一次最多添加 19 位伙伴"));
        }
        let companions = companions
            .iter()
            .map(|n| name(n))
            .collect::<CoreResult<Vec<_>>>()?;
        let id = random_id("trip");
        let member_id = random_id("member");
        let path = self.ledger_path(&id);
        let mut session = WorkspaceSession::empty_on_repo(
            LedgerRepository::open_file(&path)?,
            Some(path.to_string_lossy().into_owned()),
            id.clone(),
            member_id.clone(),
            self.device_id.clone(),
            self.keypair.clone(),
            GroupCipher::generate(1),
        );
        let mut participants = BTreeMap::new();
        participants.insert(
            member_id.clone(),
            ParticipantProfile {
                participant_id: member_id.clone(),
                display_name,
                bound_public_key: Some(self.keypair.public_key_b64()),
                role: Role::Owner,
                active: true,
                extra_capabilities: Default::default(),
            },
        );
        for display_name in companions {
            let pid = random_id("member");
            participants.insert(
                pid.clone(),
                ParticipantProfile {
                    participant_id: pid,
                    display_name,
                    bound_public_key: None,
                    role: Role::Member,
                    active: true,
                    extra_capabilities: Default::default(),
                },
            );
        }
        let policy = PolicyPayload {
            policy_seq: 1,
            previous_policy_event_id: None,
            group_name: group_name.clone(),
            owner_member_id: member_id.clone(),
            settlement_coordinator_id: member_id.clone(),
            currencies: CurrencySpec::default_catalog(),
            participants,
            accepted_device_checkpoints: Default::default(),
        };
        let event = SignedEvent::sign_new(
            UnsignedEvent {
                schema_version: CURRENT_SCHEMA_VERSION,
                group_id: id.clone(),
                author_member_id: member_id.clone(),
                author_public_key: self.keypair.public_key_b64(),
                device_id: self.device_id.clone(),
                sequence: 1,
                previous_event_id: None,
                policy_version_id: "GENESIS".into(),
                body: EventBody::PolicyUpdate(policy),
            },
            &self.keypair,
        )?;
        session.persist_session_metadata()?;
        session
            .repo
            .append_signed_event(&event, Some(&session.cipher))?;
        self.catalog.ledgers.push(LedgerEntry {
            group_id: id.clone(),
            group_name,
            member_id,
            legacy: false,
        });
        self.catalog.active_group_id = Some(id);
        self.save_catalog()?;
        self.session = Some(session);
        Ok(())
    }
    fn update_policy(&mut self, policy: PolicyPayload) -> CoreResult<()> {
        let session = self.session()?;
        let proj = session.repo.project_group(&session.group_id)?;
        let actor = &proj.active_policy.participants[&session.active_actor_id];
        if actor.role != Role::Owner || !actor.active {
            return Err(invalid("只有账本主人可以管理伙伴和认领"));
        }
        if !proj.policy_conflicts.is_empty() {
            return Err(invalid("成员权限存在并发冲突，请先核对"));
        }
        let (device, key) = session.member_keys[&session.active_actor_id].clone();
        let (sequence, previous_event_id) = session
            .repo
            .next_device_sequence(&session.group_id, &device)?;
        let mut policy = policy;
        policy.policy_seq = proj.active_policy.policy_seq + 1;
        policy.previous_policy_event_id = Some(proj.active_policy_event_id.clone());
        let event = SignedEvent::sign_new(
            UnsignedEvent {
                schema_version: CURRENT_SCHEMA_VERSION,
                group_id: session.group_id.clone(),
                author_member_id: session.active_actor_id.clone(),
                author_public_key: key.public_key_b64(),
                device_id: device,
                sequence,
                previous_event_id,
                policy_version_id: proj.active_policy_event_id,
                body: EventBody::PolicyUpdate(policy),
            },
            &key,
        )?;
        session
            .repo
            .append_signed_event(&event, Some(&session.cipher))?;
        session.persist_session_metadata()
    }
    fn approve(&mut self, raw: &str, participant_id: &str) -> CoreResult<(String, String)> {
        let request: ClaimRequest = decode("SBILL-CLAIM1:", raw)?;
        if request.body.version != 1 {
            return Err(invalid("不支持的认领版本"));
        }
        verify_ed25519_signature(
            &request.body.public_key,
            &canonical_json_bytes(&request.body)?,
            &request.signature,
        )?;
        let session = self.session()?;
        if request.body.group_id != session.group_id
            || request.body.participant_id != participant_id
        {
            return Err(invalid("认领申请不属于该账本或伙伴"));
        }
        let mut policy = session.repo.project_group(&session.group_id)?.active_policy;
        let member = policy
            .participants
            .get_mut(participant_id)
            .ok_or_else(|| invalid("伙伴不存在"))?;
        if !member.active || member.role == Role::Owner {
            return Err(invalid("该伙伴不可认领"));
        }
        if let Some(key) = &member.bound_public_key {
            if key != &request.body.public_key {
                return Err(invalid("该伙伴已由另一身份认领"));
            }
        }
        if policy.participants.values().any(|p| {
            p.participant_id != participant_id
                && p.bound_public_key.as_deref() == Some(&request.body.public_key)
        }) {
            return Err(invalid("此身份已经认领本账本中的另一个伙伴"));
        }
        policy
            .participants
            .get_mut(participant_id)
            .unwrap()
            .bound_public_key = Some(request.body.public_key.clone());
        self.update_policy(policy)?;
        let session = self.session()?;
        let welcome = Welcome {
            version: 1,
            group_id: session.group_id.clone(),
            member_id: participant_id.into(),
            public_key: request.body.public_key,
            cipher_b64: session.cipher.to_b64(),
            events: session.repo.list_events(&session.group_id)?,
        };
        let access = GroupCipher::generate(1);
        let ciphertext = access.encrypt(&serde_json::to_vec(&welcome)?, JOIN_AAD)?;
        Ok((
            format!("SBILL-JOIN1:{}", URL_SAFE_NO_PAD.encode(ciphertext)),
            access.to_b64(),
        ))
    }
    fn join(&mut self, code: &str, access_key: &str) -> CoreResult<()> {
        if code.len() > MAX_TRANSFER_BYTES {
            return Err(invalid("加入包超过 20 MiB"));
        }
        let bytes = URL_SAFE_NO_PAD
            .decode(
                code.trim()
                    .strip_prefix("SBILL-JOIN1:")
                    .ok_or_else(|| invalid("请粘贴加入包"))?,
            )
            .map_err(|_| invalid("加入包编码无效"))?;
        let welcome: Welcome = serde_json::from_slice(
            &GroupCipher::from_b64(access_key.trim(), 1)?.decrypt(&bytes, JOIN_AAD)?,
        )?;
        if welcome.version != 1 || welcome.public_key != self.keypair.public_key_b64() {
            return Err(invalid("此加入包不是发给本机身份的"));
        }
        let proj = build_projection(&welcome.group_id, &welcome.events)?;
        let member = proj
            .active_policy
            .participants
            .get(&welcome.member_id)
            .ok_or_else(|| invalid("加入包未包含成员授权"))?;
        if !member.active
            || member.bound_public_key.as_deref() != Some(&welcome.public_key)
            || !proj.policy_conflicts.is_empty()
        {
            return Err(invalid("加入授权无效或有冲突"));
        }
        if self
            .catalog
            .ledgers
            .iter()
            .any(|e| e.group_id == welcome.group_id)
        {
            return Err(invalid("本机已加入该账本，请选择它后导入普通同步包"));
        }
        let path = self.ledger_path(&welcome.group_id);
        let mut session = WorkspaceSession::empty_on_repo(
            LedgerRepository::open_file(&path)?,
            Some(path.to_string_lossy().into_owned()),
            welcome.group_id.clone(),
            welcome.member_id.clone(),
            self.device_id.clone(),
            self.keypair.clone(),
            GroupCipher::from_b64(&welcome.cipher_b64, 1)?,
        );
        session.persist_session_metadata()?;
        let result = session
            .repo
            .import_event_batch(&welcome.group_id, &welcome.events, None)?;
        if !result.rejected_events.is_empty() || result.pending_dependency_count > 0 {
            return Err(invalid("加入包事件未通过完整校验"));
        }
        self.catalog.ledgers.push(LedgerEntry {
            group_id: welcome.group_id.clone(),
            group_name: proj.active_policy.group_name,
            member_id: welcome.member_id,
            legacy: false,
        });
        self.catalog.active_group_id = Some(welcome.group_id);
        self.save_catalog()?;
        self.session = Some(session);
        Ok(())
    }
    pub fn execute(&mut self, command: AppCommand) -> CoreResult<AppSnapshot> {
        let mut transfer_code = None;
        let mut access_key = None;
        let mut claim_preview = None;
        match command {
            AppCommand::AppOpen { .. } | AppCommand::AppGet => {}
            AppCommand::AppCreateLedger {
                group_name,
                display_name,
                companions,
            } => self.create(&group_name, &display_name, companions)?,
            AppCommand::AppSelectLedger { group_id } => self.select(&group_id)?,
            AppCommand::AppShowLedgers => {
                self.session = None;
                self.catalog.active_group_id = None;
                self.save_catalog()?;
            }
            AppCommand::AppAddParticipant {
                group_id,
                display_name,
                role,
            } => {
                self.require_group(&group_id)?;
                if role == Role::Owner {
                    return Err(invalid("不能新增第二位账本主人"));
                }
                let display_name = name(&display_name)?;
                let session = self.session()?;
                let mut policy = session.repo.project_group(&session.group_id)?.active_policy;
                let id = random_id("member");
                policy.participants.insert(
                    id.clone(),
                    ParticipantProfile {
                        participant_id: id,
                        display_name,
                        bound_public_key: None,
                        role,
                        active: true,
                        extra_capabilities: Default::default(),
                    },
                );
                self.update_policy(policy)?;
            }
            AppCommand::AppUpdateParticipant {
                group_id,
                participant_id,
                display_name,
                role,
                active,
            } => {
                self.require_group(&group_id)?;
                let display_name = name(&display_name)?;
                let session = self.session()?;
                let proj = session.repo.project_group(&session.group_id)?;
                let mut policy = proj.active_policy;
                if participant_id == policy.owner_member_id || role == Role::Owner {
                    return Err(invalid("账本主人不能被删除或降权"));
                }
                let member = policy
                    .participants
                    .get_mut(&participant_id)
                    .ok_or_else(|| invalid("伙伴不存在"))?;
                if member.active
                    && (!active
                        || !member
                            .role
                            .default_capabilities()
                            .is_subset(&role.default_capabilities()))
                {
                    let events = session.repo.list_events(&session.group_id)?;
                    for (device, cursor) in proj.device_cursors {
                        if cursor.member_id == participant_id {
                            let first_pending = events
                                .iter()
                                .filter(|ev| {
                                    ev.unsigned.device_id == device
                                        && (proj.pending_reauth_events.contains(&ev.event_id)
                                            || proj
                                                .pending_dependency_events
                                                .contains(&ev.event_id))
                                })
                                .map(|ev| ev.unsigned.sequence)
                                .min();
                            let accepted = first_pending
                                .map(|seq| seq.saturating_sub(1))
                                .unwrap_or(cursor.contiguous_seq)
                                .min(cursor.contiguous_seq);
                            policy.accepted_device_checkpoints.insert(device, accepted);
                        }
                    }
                }
                member.display_name = display_name;
                member.role = role;
                member.active = active;
                self.update_policy(policy)?;
            }
            AppCommand::AppCreateClaim {
                group_id,
                participant_id,
                display_name,
            } => {
                let body = ClaimBody {
                    version: 1,
                    group_id: name(&group_id)?,
                    participant_id: name(&participant_id)?,
                    display_name: name(&display_name)?,
                    public_key: self.keypair.public_key_b64(),
                    device_id: self.device_id.clone(),
                    nonce: random_id("claim"),
                };
                let signature = self.keypair.sign(&canonical_json_bytes(&body)?);
                transfer_code = Some(encode("SBILL-CLAIM1:", &ClaimRequest { body, signature })?);
            }
            AppCommand::AppInspectClaim { group_id, request } => {
                self.require_group(&group_id)?;
                let claim: ClaimRequest = decode("SBILL-CLAIM1:", &request)?;
                verify_ed25519_signature(
                    &claim.body.public_key,
                    &canonical_json_bytes(&claim.body)?,
                    &claim.signature,
                )?;
                if claim.body.version != 1 || claim.body.group_id != group_id {
                    return Err(invalid("认领申请不属于该账本"));
                }
                claim_preview = Some(json!({"display_name":claim.body.display_name,
                    "participant_id":claim.body.participant_id,
                    "fingerprint":blake3_hash_b64(claim.body.public_key.as_bytes())}));
            }
            AppCommand::AppApproveClaim {
                group_id,
                request,
                participant_id,
            } => {
                self.require_group(&group_id)?;
                let (code, key) = self.approve(&request, &participant_id)?;
                transfer_code = Some(code);
                access_key = Some(key);
            }
            AppCommand::AppJoinLedger {
                welcome,
                access_key,
            } => self.join(&welcome, &access_key)?,
            AppCommand::AppLedgerCommand {
                group_id,
                mut command,
            } => {
                let session = self.session()?;
                if group_id != session.group_id {
                    return Err(invalid("账本已切换，请重新打开操作页面"));
                }
                let op = command["op"].as_str().ok_or_else(|| invalid("无效操作"))?;
                if ![
                    "InitOrGetSnapshot",
                    "SetFxRate",
                    "SetSettlementCurrency",
                    "UpsertExpense",
                    "DeclareRepayment",
                    "ConfirmRepayment",
                    "DisputeRepayment",
                    "MapLateRepayment",
                    "ProposeSettlement",
                    "ApproveSettlement",
                    "CommitSettlement",
                    "ExportTripDelta",
                    "ImportTripDelta",
                    "ConfigureWebDav",
                    "SyncWebDavNow",
                    "ApplyWebDavHttpSync",
                    "GenerateOpticalFrames",
                    "IngestOpticalFrame",
                    "ExportIdentityBackup",
                    "RestoreIdentityBackup",
                    "AddCustomCategory",
                    "RemoveCustomCategory",
                ]
                .contains(&op)
                {
                    return Err(invalid("此操作不在正式账本中开放"));
                }
                let op = op.to_string();
                let proj = session.repo.project_group(&session.group_id)?;
                let actor = proj
                    .active_policy
                    .participants
                    .get(&session.active_actor_id)
                    .ok_or_else(|| invalid("本机成员不存在"))?;
                let read_only = [
                    "InitOrGetSnapshot",
                    "ExportTripDelta",
                    "ImportTripDelta",
                    "SetSettlementCurrency",
                    "ConfigureWebDav",
                    "SyncWebDavNow",
                    "ApplyWebDavHttpSync",
                    "GenerateOpticalFrames",
                    "IngestOpticalFrame",
                    "ExportIdentityBackup",
                    "RestoreIdentityBackup",
                ]
                .contains(&op.as_str());
                let self_confirmation = [
                    "ApproveSettlement",
                    "ConfirmRepayment",
                    "DeclareRepayment",
                    "DisputeRepayment",
                ]
                .contains(&op.as_str());
                if !read_only && (!actor.active || (actor.role == Role::Viewer && !self_confirmation)) {
                    return Err(invalid("当前身份没有修改账本的权限"));
                }
                if op == "DeclareRepayment"
                    && command["args"]["payer_id"].as_str() != Some(&session.active_actor_id)
                {
                    return Err(invalid("只能声明本人已还款"));
                }
                if op == "UpsertExpense"
                    && command["args"]["parent_revision_event_ids"]
                        .as_array()
                        .is_some_and(|v| v.is_empty())
                {
                    let args = &command["args"];
                    let mut ids: Vec<&str> = args["payers"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter_map(|p| p["participant_id"].as_str())
                        .collect();
                    if let Some(equal) = args["split_rule"]["Equal"]["participants"].as_array() {
                        ids.extend(equal.iter().filter_map(Value::as_str));
                    }
                    for kind in ["ExactAmounts", "Ratios", "Weights"] {
                        if let Some(fields) = args["split_rule"][kind].as_object() {
                            for value in fields.values() {
                                if let Some(map) = value.as_object() {
                                    ids.extend(map.keys().map(String::as_str));
                                }
                            }
                        }
                    }
                    if ids.iter().any(|id| {
                        !proj
                            .active_policy
                            .participants
                            .get(*id)
                            .is_some_and(|p| p.active)
                    }) {
                        return Err(invalid("新账目不能包含已移出的伙伴"));
                    }
                }
                if let Some(args) = command.get_mut("args").and_then(Value::as_object_mut) {
                    if args.contains_key("actor_id") {
                        args.insert("actor_id".into(), json!(session.active_actor_id));
                    }
                    for id_field in ["expense_id", "payment_id", "snapshot_id", "id"] {
                        if args.contains_key(id_field)
                            && (id_field != "expense_id"
                                || args
                                    .get("parent_revision_event_ids")
                                    .and_then(Value::as_array)
                                    .is_some_and(Vec::is_empty))
                            && op != "RemoveCustomCategory"
                            && ![
                                "ApproveSettlement",
                                "CommitSettlement",
                                "ConfirmRepayment",
                                "DisputeRepayment",
                                "MapLateRepayment",
                            ]
                            .contains(&op.as_str())
                        {
                            args.insert(id_field.into(), json!(random_id(id_field)));
                        }
                    }
                }
                let response: FfiResponse = serde_json::from_str(&dispatch_ffi_json_on_session(
                    session,
                    &serde_json::to_string(&command)?,
                ))?;
                if !response.ok {
                    return Err(invalid(response.error.as_deref().unwrap_or("账本操作失败")));
                }
            }
        }
        let active_ledger = self
            .session
            .as_ref()
            .map(WorkspaceSession::build_ui_snapshot)
            .transpose()?;
        Ok(AppSnapshot {
            ledgers: self.catalog.ledgers.clone(),
            active_ledger,
            identity_fingerprint: blake3_hash_b64(self.keypair.public_key_b64().as_bytes()),
            transfer_code,
            access_key,
            claim_preview,
        })
    }
}

static APP: OnceLock<Mutex<Option<AppWorkspace>>> = OnceLock::new();
pub fn dispatch_app_json(raw: &str) -> String {
    let result = (|| -> CoreResult<AppSnapshot> {
        let command: AppCommand = serde_json::from_str(raw)?;
        let mut guard = APP
            .get_or_init(|| Mutex::new(None))
            .lock()
            .map_err(|_| invalid("账本会话不可用"))?;
        if let AppCommand::AppOpen { db_path } = &command {
            *guard = Some(AppWorkspace::open(db_path)?);
        }
        guard
            .as_mut()
            .ok_or_else(|| invalid("尚未打开本机账本目录"))?
            .execute(command)
    })();
    match result {
        Ok(workspace) => json!({"ok":true,"workspace":workspace}).to_string(),
        Err(e) => json!({"ok":false,"error":e.to_string()}).to_string(),
    }
}

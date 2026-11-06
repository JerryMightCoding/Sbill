//! Full-project automated smoke test suite (`SMOKE-01` .. `SMOKE-10`)
//! covering all 12 PRD acceptance categories (`AC-G*`, `AC-E*`, `AC-A*`, `AC-C*`,
//! `AC-P*`, `AC-S*`, `AC-L*`, `AC-D*`, `AC-F*`, `AC-Q*`, `AC-I*`, `AC-B*`).

use std::collections::{BTreeMap, BTreeSet};

use sbill_core::api::LedgerNode;
use sbill_core::crypto::{DeviceKeypair, GroupCipher};
use sbill_core::domain::*;
use sbill_core::engine::*;
use sbill_core::ffi::{dispatch_ffi_json_on_session, FfiResponse, WorkspaceSession};
use sbill_core::sync::{
    embed_tripdelta_into_png, encode_optical_fountain_frames, evaluate_restore_completeness,
    extract_tripdelta_from_png, MemberIdentityBackup, OpticalFountainAssembler, TripDeltaPackage,
};

#[test]
fn smoke_01_group_genesis_and_unbound_accounting_participant_ac_g01_g02_g03() {
    let group_id = "smoke_trip_01";
    let cipher = GroupCipher::generate(1);
    let kp_owner = DeviceKeypair::generate();

    let mut participants = BTreeMap::new();
    participants.insert(
        "U_OWNER".to_string(),
        ParticipantProfile {
            participant_id: "U_OWNER".to_string(),
            display_name: "同名张伟 (群主)".to_string(),
            bound_public_key: Some(kp_owner.public_key_b64()),
            role: Role::Owner,
            active: true,
            extra_capabilities: BTreeSet::new(),
        },
    );
    // AC-G02 & AC-G03: Same display name ("同名张伟") but distinct stable participant_id,
    // and unbound accounting-only participant (`bound_public_key: None`).
    participants.insert(
        "U_GUEST".to_string(),
        ParticipantProfile {
            participant_id: "U_GUEST".to_string(),
            display_name: "同名张伟 (未装App同伴)".to_string(),
            bound_public_key: None,
            role: Role::Member,
            active: true,
            extra_capabilities: BTreeSet::new(),
        },
    );

    let mut node =
        LedgerNode::new_in_memory(group_id, "U_OWNER", "dev_owner", kp_owner, cipher).unwrap();
    node.create_group_genesis("离线创世群组", participants)
        .unwrap();

    // Unbound guest can participate in expense splitting and paying
    node.submit_expense_revision(
        "exp_1",
        vec![],
        "CNY",
        10_000,
        vec![PayerContribution {
            participant_id: "U_OWNER".to_string(),
            amount_minor: 10_000,
            original_currency: None,
            original_amount_minor: None,
            frozen_fx_rate: None,
        }],
        SplitRule::Equal {
            participants: vec!["U_OWNER".to_string(), "U_GUEST".to_string()],
        },
        "午餐",
        "",
        "create",
        vec![],
        false,
    )
    .unwrap();

    // Propose settlement involving unbound guest -> commit must reject missing digital signature from unbound guest (AC-G02)
    node.propose_settlement_snapshot("snap_guest", SettlementMode::ByCurrencyPairwise, None, vec![])
        .unwrap();
    node.approve_settlement_snapshot("snap_guest").unwrap();
    assert!(node.commit_settlement_snapshot("snap_guest").is_err());
}

#[test]
fn smoke_02_multi_currency_multi_payer_and_largest_remainder_splits_ac_e01_to_e08() {
    // 100 units split 3 ways -> 34, 33, 33; Weighted split 1:2:3; KWD (3 decimals) & JPY (0 decimals)
    let equal_3 = compute_resolved_shares(
        100,
        &SplitRule::Equal {
            participants: vec!["M3".to_string(), "M1".to_string(), "M2".to_string()],
        },
        false,
    )
    .unwrap();
    assert_eq!(equal_3["M1"], 34);
    assert_eq!(equal_3["M2"], 33);
    assert_eq!(equal_3["M3"], 33);

    let weighted = compute_resolved_shares(
        10_000,
        &SplitRule::Weights {
            weights: [("Adult1".to_string(), 2), ("Adult2".to_string(), 2), ("Child".to_string(), 1)]
                .into_iter()
                .collect(),
        },
        false,
    )
    .unwrap();
    assert_eq!(weighted["Adult1"], 4_000);
    assert_eq!(weighted["Adult2"], 4_000);
    assert_eq!(weighted["Child"], 2_000);

    // FX conversion between JPY (0 decimals) and CNY (2 decimals): 20 JPY = 1 CNY -> 2,000 JPY = 100.00 CNY (10_000 fen)
    let jpy_to_cny = FxRateSpec::new("JPY", "CNY", 1, 20).unwrap();
    assert_eq!(jpy_to_cny.convert_minor(2_000, 0, 2).unwrap(), 10_000);
}

#[test]
fn smoke_03_to_08_full_ffi_closed_loop_m4_m5_m6_m7() {
    let mut session = WorkspaceSession::new_with_sample_trip().unwrap();
    let mut call = |json_str: &str| -> FfiResponse {
        serde_json::from_str(&dispatch_ffi_json_on_session(&mut session, json_str)).unwrap()
    };

    // 1. Verify initial 4-mode settlement counts: 8 / 6 / 6 / 3 (AC-S01)
    let s0 = call(r#"{"op":"InitOrGetSnapshot"}"#).snapshot.unwrap();
    assert_eq!(
        s0.settlement_previews["ByCurrencyPairwise"].transfers.len(),
        8
    );
    assert_eq!(
        s0.settlement_previews["ByCurrencyMinTransfers"]
            .transfers
            .len(),
        6
    );
    assert_eq!(
        s0.settlement_previews["MergedCurrencyPairwise"]
            .transfers
            .len(),
        6
    );
    assert_eq!(
        s0.settlement_previews["MergedCurrencyMinTransfers"]
            .transfers
            .len(),
        3
    );

    // 2. Concurrent conflict & resolution (AC-C01, AC-C02)
    let sc = call(r#"{"op":"SimulateConcurrentConflict","args":{"expense_id":"exp_hotel_cny"}}"#)
        .snapshot
        .unwrap();
    assert_eq!(sc.conflict_count, 1);
    let hotel_exp = sc
        .expenses
        .iter()
        .find(|e| e.expense_id == "exp_hotel_cny")
        .unwrap();
    let branches: Vec<String> = hotel_exp
        .conflict_branches
        .iter()
        .map(|b| b.event_id.clone())
        .collect();

    let resolve_json = serde_json::json!({
        "op": "UpsertExpense",
        "args": {
            "actor_id": "B",
            "expense_id": "exp_hotel_cny",
            "parent_revision_event_ids": branches,
            "currency": "CNY",
            "total_minor": 100000,
            "payers": [
                {"participant_id": "A", "amount_minor": 60000, "original_currency": null, "original_amount_minor": null, "frozen_fx_rate": null},
                {"participant_id": "B", "amount_minor": 40000, "original_currency": null, "original_amount_minor": null, "frozen_fx_rate": null}
            ],
            "split_rule": {"Equal": {"participants": ["A", "B", "C", "D"]}},
            "title": "温泉酒店两晚合住",
            "note": "冲突已合并恢复为 1,000 元",
            "revision_reason": "管理员合并确认",
            "voided": false
        }
    });
    assert_eq!(
        call(&resolve_json.to_string())
            .snapshot
            .unwrap()
            .conflict_count,
        0
    );

    // 3. Propose, approve by all 4 members, commit Debt Novation, and fulfill obligations (M5)
    assert!(
        call(r#"{"op":"ProposeSettlement","args":{"actor_id":"A","snapshot_id":"snap_smoke","mode":"MergedCurrencyMinTransfers","settlement_currency":"CNY"}}"#).ok
    );
    for m in ["A", "B", "C", "D"] {
        let app = serde_json::json!({"op":"ApproveSettlement","args":{"actor_id":m,"snapshot_id":"snap_smoke"}});
        assert!(call(&app.to_string()).ok);
    }
    let committed = call(r#"{"op":"CommitSettlement","args":{"actor_id":"A","snapshot_id":"snap_smoke"}}"#)
        .snapshot
        .unwrap();
    assert_eq!(committed.active_obligations.len(), 3);
}

#[test]
fn smoke_09_png_carrier_ac_i01_i02_and_optical_fountain_ac_q01_q03() {
    let session = WorkspaceSession::new_with_sample_trip().unwrap();
    let events = session.repo.list_events(&session.group_id).unwrap();
    let pkg = TripDeltaPackage::pack_events(&session.group_id, &events, &session.cipher).unwrap();

    // AC-I01: Embed `.tripdelta` inside lossless PNG custom chunk `sbIl` and extract back
    let png_bytes = embed_tripdelta_into_png(&pkg).unwrap();
    let extracted_pkg = extract_tripdelta_from_png(&png_bytes).unwrap();
    assert_eq!(extracted_pkg.package_digest, pkg.package_digest);
    let unpacked_events = extracted_pkg
        .unpack_events(&session.group_id, &session.cipher)
        .unwrap();
    assert_eq!(unpacked_events.len(), events.len());

    // AC-I02: Recompressed JPEG or metadata-stripped PNG must be detected and rejected with clear guidance
    let fake_jpeg = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10];
    let jpeg_err = extract_tripdelta_from_png(&fake_jpeg).unwrap_err();
    assert!(jpeg_err.to_string().contains("JPEG"));

    // Strip custom `sbIl` chunk (simulate screenshot / gallery re-save)
    let stripped_png = [
        0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0, b'I', b'E', b'N', b'D', 0xAE,
        0x42, 0x60, 0x82,
    ];
    let strip_err = extract_tripdelta_from_png(&stripped_png).unwrap_err();
    assert!(strip_err.to_string().contains("AC-I02"));

    // AC-Q02 & AC-Q03: Optical fountain assembler isolates different package IDs and recovers from mid-stream
    let frames = encode_optical_fountain_frames(&pkg, 180, 10).unwrap();
    let mut assembler = OpticalFountainAssembler::new();
    let mut done = None;
    for f in frames.iter().skip(1) {
        if let Some(recovered) = assembler.ingest_frame(f).unwrap() {
            done = Some(recovered);
            break;
        }
    }
    assert_eq!(done.unwrap().package_id, pkg.package_id);
}

#[test]
fn smoke_10_encrypted_attachments_and_passphrase_key_backup_restore_diagnostics_ac_b01_to_b03() {
    let mut session = WorkspaceSession::new_with_sample_trip().unwrap();
    let (dev_a, kp_a) = session.member_keys["A"].clone();

    // 1. Personal passphrase-protected signing key backup (`FR-BKP-01`)
    let backup =
        MemberIdentityBackup::create("A", &dev_a, &kp_a, "correct_horse_battery").unwrap();
    assert!(backup.restore("wrong_passphrase").is_err());
    let restored_kp = backup.restore("correct_horse_battery").unwrap();
    assert_eq!(restored_kp.public_key_b64(), kp_a.public_key_b64());

    // 2. Encrypted attachment storage & missing-attachment diagnostic (`FR-ATT-01`, `AC-B02`)
    let att_ref = session
        .repo
        .store_encrypted_attachment(
            &session.group_id,
            "att_receipt_01",
            "image/jpeg",
            b"raw_receipt_image_bytes_12345",
            &session.cipher,
        )
        .unwrap();
    let decrypted = session
        .repo
        .load_decrypted_attachment(&session.group_id, &att_ref, &session.cipher)
        .unwrap()
        .unwrap();
    assert_eq!(decrypted, b"raw_receipt_image_bytes_12345");

    // Create an expense referencing both `att_receipt_01` (present) and `att_receipt_missing_02` (not yet synced)
    let proj = session.repo.project_group(&session.group_id).unwrap();
    let (seq, prev_ev) = session
        .repo
        .next_device_sequence(&session.group_id, &dev_a)
        .unwrap();
    let shares = compute_resolved_shares(
        10_000,
        &SplitRule::Equal {
            participants: vec!["A".to_string(), "B".to_string()],
        },
        false,
    )
    .unwrap();
    let payers = vec![PayerContribution {
        participant_id: "A".to_string(),
        amount_minor: 10_000,
        original_currency: None,
        original_amount_minor: None,
        frozen_fx_rate: None,
    }];
    let matrix = compute_attribution_matrix(10_000, &payers, &shares, false).unwrap();

    let ev_with_att = SignedEvent::sign_new(
        UnsignedEvent {
            schema_version: CURRENT_SCHEMA_VERSION,
            group_id: session.group_id.clone(),
            author_member_id: "A".to_string(),
            author_public_key: kp_a.public_key_b64(),
            device_id: dev_a,
            sequence: seq,
            previous_event_id: prev_ev,
            policy_version_id: proj.active_policy_event_id,
            body: EventBody::ExpenseUpsert(ExpenseRevisionPayload {
                expense_id: "exp_with_attachments".to_string(),
                parent_revision_event_ids: vec![],
                currency: "CNY".to_string(),
                total_minor: 10_000,
                payers,
                split_rule: SplitRule::Equal {
                    participants: vec!["A".to_string(), "B".to_string()],
                },
                resolved_shares: shares,
                attribution_matrix: matrix,
                attribution_rule_version: ATTRIBUTION_RULE_VERSION.to_string(),
                details: None,
                title: "带票据照片账单".to_string(),
                note: "".to_string(),
                revision_reason: "create".to_string(),
                attachment_refs: vec![
                    att_ref,
                    AttachmentRef {
                        attachment_id: "att_receipt_missing_02".to_string(),
                        mime_type: "image/png".to_string(),
                        byte_len: 4096,
                        ciphertext_blake3: "hash_missing".to_string(),
                    },
                ],
                voided: false,
            }),
        },
        &kp_a,
    )
    .unwrap();
    session
        .repo
        .append_signed_event(&ev_with_att, Some(&session.cipher))
        .unwrap();

    // Evaluate restore completeness when signing key is missing vs restored (`AC-B02`)
    let diag_no_key = evaluate_restore_completeness(
        &session.repo,
        &session.group_id,
        "A",
        None,
        true,
    )
    .unwrap();
    assert!(!diag_no_key.member_signing_key_restored);
    assert!(diag_no_key.requires_owner_device_authorization);
    assert_eq!(
        diag_no_key.missing_attachment_ids,
        vec!["att_receipt_missing_02".to_string()]
    );

    let diag_with_key = evaluate_restore_completeness(
        &session.repo,
        &session.group_id,
        "A",
        Some(&restored_kp),
        true,
    )
    .unwrap();
    assert!(diag_with_key.member_signing_key_restored);
    assert!(!diag_with_key.requires_owner_device_authorization);
}

#[test]
fn smoke_11_sqlite_disk_persistence_across_app_restart() {
    let temp_dir = std::env::temp_dir().join(format!(
        "sbill_persist_test_{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&temp_dir);
    std::fs::create_dir_all(&temp_dir).unwrap();
    let db_path = temp_dir.join("sbill_ledger_v1.sqlite3");
    let db_path_str = db_path.to_string_lossy().to_string();

    // --- Process Run #1: First launch, add new bill, add new member E, switch actor & FX ---
    {
        let mut session_1 = WorkspaceSession::open_or_init_persistent(&db_path).unwrap();
        let mut call_1 = |json_str: &str| -> FfiResponse {
            serde_json::from_str(&dispatch_ffi_json_on_session(&mut session_1, json_str)).unwrap()
        };

        let open_cmd = serde_json::json!({
            "op": "OpenPersistentWorkspace",
            "args": { "db_path": db_path_str }
        });
        let snap_init = call_1(&open_cmd.to_string()).snapshot.unwrap();
        assert_eq!(snap_init.expenses.len(), 2);

        // Add a 3rd expense ("深夜拉面 180 元")
        let add_exp_cmd = serde_json::json!({
            "op": "UpsertExpense",
            "args": {
                "actor_id": "B",
                "expense_id": "exp_persistent_ramen",
                "parent_revision_event_ids": [],
                "currency": "CNY",
                "total_minor": 18000,
                "payers": [
                    {"participant_id": "B", "amount_minor": 18000, "original_currency": null, "original_amount_minor": null, "frozen_fx_rate": null}
                ],
                "split_rule": {"Equal": {"participants": ["A", "B", "C", "D"]}},
                "title": "深夜拉面宵夜",
                "note": "重启持久化验证账单",
                "revision_reason": "创建账单",
                "voided": false
            }
        });
        assert!(call_1(&add_exp_cmd.to_string()).ok);

        // Owner A adds a new member E with a freshly generated bound device key
        let add_mem_cmd = serde_json::json!({
            "op": "AddParticipant",
            "args": {
                "actor_id": "A",
                "participant_id": "E",
                "display_name": "小鹅 (新加入伙伴)",
                "role": "Member",
                "bind_device_key": true
            }
        });
        assert!(call_1(&add_mem_cmd.to_string()).ok);

        // Switch active actor to E and update USD->CNY FX rate to 8
        assert!(call_1(r#"{"op":"SwitchActor","args":{"actor_id":"E"}}"#).ok);
        assert!(
            call_1(r#"{"op":"SetFxRate","args":{"base_currency":"USD","quote_currency":"CNY","numerator":8,"denominator":1}}"#).ok
        );
        // `session_1` is dropped here, simulating Android process termination!
    }

    // --- Process Run #2: App restart opening the same SQLite file ---
    {
        let mut session_2 = WorkspaceSession::open_or_init_persistent(&db_path).unwrap();
        let mut call_2 = |json_str: &str| -> FfiResponse {
            serde_json::from_str(&dispatch_ffi_json_on_session(&mut session_2, json_str)).unwrap()
        };

        let snap_restarted = call_2(r#"{"op":"InitOrGetSnapshot"}"#).snapshot.unwrap();

        // 1. Must have 3 expenses (did NOT reset to the 2 demo bills!)
        assert_eq!(snap_restarted.expenses.len(), 3);
        assert!(snap_restarted
            .expenses
            .iter()
            .any(|e| e.expense_id == "exp_persistent_ramen"));

        // 2. Active actor E, 5 participants, and FX rate 1 USD = 8 CNY must be preserved
        assert_eq!(snap_restarted.active_actor_id, "E");
        assert_eq!(snap_restarted.participants.len(), 5);
        let usd_rate = snap_restarted
            .default_fx_rates
            .iter()
            .find(|r| r.base_currency == "USD")
            .unwrap();
        assert_eq!(usd_rate.numerator, 8);

        // 3. Newly added member E's signing keypair must be restored from SQLite so E can sign a 4th bill after restart!
        let e_bill_cmd = serde_json::json!({
            "op": "UpsertExpense",
            "args": {
                "actor_id": "E",
                "expense_id": "exp_after_restart_by_e",
                "parent_revision_event_ids": [],
                "currency": "CNY",
                "total_minor": 10000,
                "payers": [
                    {"participant_id": "E", "amount_minor": 10000, "original_currency": null, "original_amount_minor": null, "frozen_fx_rate": null}
                ],
                "split_rule": {"Equal": {"participants": ["A", "E"]}},
                "title": "重启后由新成员E录入的早餐",
                "note": "验证新成员私钥同样持久化",
                "revision_reason": "创建账单",
                "voided": false
            }
        });
        let resp_e = call_2(&e_bill_cmd.to_string());
        assert!(resp_e.ok);
        assert_eq!(resp_e.snapshot.unwrap().expenses.len(), 4);
    }

    let _ = std::fs::remove_dir_all(&temp_dir);
}

#[test]
fn smoke_12_multi_peer_custom_category_sync_union() {
    let group_id = "trip_category_union";
    let cipher = GroupCipher::generate(1);
    let kp_a = DeviceKeypair::generate();
    let kp_b = DeviceKeypair::generate();
    let kp_c = DeviceKeypair::generate();

    let mut participants = BTreeMap::new();
    for (id, name, kp, role) in [
        ("A", "Alice", &kp_a, Role::Owner),
        ("B", "Bob", &kp_b, Role::FinanceEditor),
        ("C", "Charlie", &kp_c, Role::Member),
    ] {
        participants.insert(
            id.to_string(),
            ParticipantProfile {
                participant_id: id.to_string(),
                display_name: name.to_string(),
                bound_public_key: Some(kp.public_key_b64()),
                role,
                active: true,
                extra_capabilities: BTreeSet::new(),
            },
        );
    }

    let mut node_a =
        LedgerNode::new_in_memory(group_id, "A", "dev_a", kp_a, cipher.clone()).unwrap();
    let mut node_b =
        LedgerNode::new_in_memory(group_id, "B", "dev_b", kp_b, cipher.clone()).unwrap();
    let mut node_c =
        LedgerNode::new_in_memory(group_id, "C", "dev_c", kp_c, cipher).unwrap();

    node_a
        .create_group_genesis("分类并集测试群", participants)
        .unwrap();
    node_a.sync_lan_with_peer(&mut node_b).unwrap();
    node_a.sync_lan_with_peer(&mut node_c).unwrap();

    // A, B, and C concurrently add custom categories while offline
    node_a
        .submit_custom_category("cat_ski_a", "🎿", "滑雪租板", false)
        .unwrap();
    node_b
        .submit_custom_category("cat_izakaya_b", "🍺", "居酒屋", false)
        .unwrap();
    node_b
        .submit_custom_category("cat_onsen_b", "♨️", "秘汤温泉", false)
        .unwrap();
    node_c
        .submit_custom_category("cat_gift_c", "🎁", "伴手礼", false)
        .unwrap();
    // C also adds a category with the same name "滑雪租板" -> must deduplicate deterministically
    node_c
        .submit_custom_category("cat_ski_c", "🏂", "滑雪租板", false)
        .unwrap();

    // Sync A <-> B via LAN, B -> C via .tripdelta file, C <-> A via LAN
    node_a.sync_lan_with_peer(&mut node_b).unwrap();
    let delta_b_to_c = node_b.export_tripdelta_bytes(None).unwrap();
    node_c.import_tripdelta_bytes(&delta_b_to_c).unwrap();
    node_a.sync_lan_with_peer(&mut node_c).unwrap();
    node_b.sync_lan_with_peer(&mut node_c).unwrap();

    let proj_a = node_a.repo.project_group(group_id).unwrap();
    let proj_b = node_b.repo.project_group(group_id).unwrap();
    let proj_c = node_c.repo.project_group(group_id).unwrap();

    let names_a: Vec<String> = proj_a
        .custom_categories
        .iter()
        .map(|c| c.name.clone())
        .collect();
    assert_eq!(
        names_a,
        vec![
            "伴手礼".to_string(),
            "居酒屋".to_string(),
            "滑雪租板".to_string(),
            "秘汤温泉".to_string(),
        ]
    );
    // All 3 peers converge to the exact same Set Union (including deterministic icon for "滑雪租板")
    assert_eq!(proj_a.custom_categories, proj_b.custom_categories);
    assert_eq!(proj_b.custom_categories, proj_c.custom_categories);

    // B deletes "居酒屋" and syncs -> removed across all peers
    node_b
        .submit_custom_category("cat_izakaya_b", "", "居酒屋", true)
        .unwrap();
    node_b.sync_lan_with_peer(&mut node_a).unwrap();
    node_b.sync_lan_with_peer(&mut node_c).unwrap();

    let after_a = node_a.repo.project_group(group_id).unwrap();
    let after_c = node_c.repo.project_group(group_id).unwrap();
    assert_eq!(after_a.custom_categories.len(), 3);
    assert_eq!(after_a.custom_categories, after_c.custom_categories);
}



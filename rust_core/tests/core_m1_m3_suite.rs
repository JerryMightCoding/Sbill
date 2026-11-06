use std::collections::{BTreeMap, BTreeSet};

use sbill_core::api::LedgerNode;
use sbill_core::crypto::{
    canonical_json_bytes, compress_zlib, decompress_zlib_bounded, DeviceKeypair, GroupCipher,
};
use sbill_core::domain::*;
use sbill_core::engine::*;
use sbill_core::error::CoreError;
use sbill_core::storage::{build_projection, EventApplyStatus, RepaymentStatus};
use sbill_core::sync::{
    encode_optical_fountain_frames, opaque_group_directory_id, sync_with_webdav,
    InMemoryWebDavStore, OpticalFountainAssembler, TripDeltaPackage, WebDavRemoteStore,
};

fn setup_four_member_group() -> (LedgerNode, LedgerNode, LedgerNode, LedgerNode) {
    let group_id = "trip_japan_2026";
    let cipher = GroupCipher::generate(1);

    let kp_a = DeviceKeypair::generate();
    let kp_b = DeviceKeypair::generate();
    let kp_c = DeviceKeypair::generate();
    let kp_d = DeviceKeypair::generate();

    let mut participants = BTreeMap::new();
    participants.insert(
        "A".to_string(),
        ParticipantProfile {
            participant_id: "A".to_string(),
            display_name: "Alice (Owner)".to_string(),
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
            display_name: "Bob (FinanceEditor)".to_string(),
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
            display_name: "Charlie (Member)".to_string(),
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
            display_name: "Diana (Member)".to_string(),
            bound_public_key: Some(kp_d.public_key_b64()),
            role: Role::Member,
            active: true,
            extra_capabilities: BTreeSet::new(),
        },
    );

    let mut node_a =
        LedgerNode::new_in_memory(group_id, "A", "dev_a", kp_a, cipher.clone()).unwrap();
    let mut node_b =
        LedgerNode::new_in_memory(group_id, "B", "dev_b", kp_b, cipher.clone()).unwrap();
    let mut node_c =
        LedgerNode::new_in_memory(group_id, "C", "dev_c", kp_c, cipher.clone()).unwrap();
    let mut node_d =
        LedgerNode::new_in_memory(group_id, "D", "dev_d", kp_d, cipher).unwrap();

    node_a
        .create_group_genesis("2026 秋季出游账本", participants)
        .unwrap();

    node_a.sync_lan_with_peer(&mut node_b).unwrap();
    node_a.sync_lan_with_peer(&mut node_c).unwrap();
    node_a.sync_lan_with_peer(&mut node_d).unwrap();

    (node_a, node_b, node_c, node_d)
}

#[test]
fn test_m1_crypto_canonical_json_and_zip_bomb_defense() {
    let kp = DeviceKeypair::generate();
    let msg = b"canonical ledger payload";
    let sig = kp.sign(msg);
    assert!(sbill_core::crypto::verify_ed25519_signature(&kp.public_key_b64(), msg, &sig).is_ok());
    assert!(
        sbill_core::crypto::verify_ed25519_signature(&kp.public_key_b64(), b"tampered", &sig)
            .is_err()
    );

    // XChaCha20-Poly1305 encryption & AAD binding
    let cipher = GroupCipher::generate(1);
    let ct = cipher.encrypt(b"secret expense", b"group_1").unwrap();
    assert_eq!(
        cipher.decrypt(&ct, b"group_1").unwrap(),
        b"secret expense"
    );
    assert!(cipher.decrypt(&ct, b"wrong_group_aad").is_err());

    // Canonical JSON key ordering determinism
    let v1: serde_json::Value = serde_json::json!({"b": 1, "a": {"y": 2, "x": 3}});
    let v2: serde_json::Value = serde_json::json!({"a": {"x": 3, "y": 2}, "b": 1});
    assert_eq!(
        canonical_json_bytes(&v1).unwrap(),
        canonical_json_bytes(&v2).unwrap()
    );

    // Bounded decompression defense (AC-F03)
    let large_zeros = vec![0u8; 8192];
    let compressed = compress_zlib(&large_zeros).unwrap();
    assert!(compressed.len() < 200);
    let err = decompress_zlib_bounded(&compressed, 1024).unwrap_err();
    assert!(matches!(err, CoreError::LimitExceeded(_)));
}

#[test]
fn test_m2_splits_largest_remainder_and_mixed_currency_bill() {
    // AC-E03: 100 cents split equally among 3 members -> 34, 33, 33 with deterministic tie-break
    let shares = compute_resolved_shares(
        100,
        &SplitRule::Equal {
            participants: vec!["C".to_string(), "A".to_string(), "B".to_string()],
        },
        false,
    )
    .unwrap();
    assert_eq!(shares["A"], 34);
    assert_eq!(shares["B"], 33);
    assert_eq!(shares["C"], 33);
    assert_eq!(shares.values().sum::<i64>(), 100);

    // AC-E02 & AC-E07: Mixed currency payment on a single 1,000.00 CNY bill (100_000 fen):
    // A pays 60.00 USD (6_000 cents) at frozen rate 1 USD = 7 CNY -> 420.00 CNY (42_000 fen),
    // B pays 580.00 CNY (58_000 fen), only C and D consume (50_000 fen each).
    let (mut node_a, _, _, _) = setup_four_member_group();
    let fx = FxRateSpec::new("USD", "CNY", 7, 1).unwrap();
    let ev = node_a
        .submit_expense_revision(
            "exp_mixed_pay",
            vec![],
            "CNY",
            100_000,
            vec![
                PayerContribution {
                    participant_id: "A".to_string(),
                    amount_minor: 42_000,
                    original_currency: Some("USD".to_string()),
                    original_amount_minor: Some(6_000),
                    frozen_fx_rate: Some(fx.clone()),
                },
                PayerContribution {
                    participant_id: "B".to_string(),
                    amount_minor: 58_000,
                    original_currency: None,
                    original_amount_minor: None,
                    frozen_fx_rate: None,
                },
            ],
            SplitRule::Equal {
                participants: vec!["C".to_string(), "D".to_string()],
            },
            "代订门票",
            "A用美元卡+B用人民币垫付，仅C和D参加",
            "initial",
            vec![],
            false,
        )
        .unwrap();
    assert!(!ev.event_id.is_empty());

    // Tampered converted amount must be rejected (AC-E05 / AC-E07)
    let bad_res = node_a.submit_expense_revision(
        "exp_bad_fx",
        vec![],
        "CNY",
        100_000,
        vec![PayerContribution {
            participant_id: "A".to_string(),
            amount_minor: 100_000,
            original_currency: Some("USD".to_string()),
            original_amount_minor: Some(6_000), // 60 USD * 7 != 1000 CNY
            frozen_fx_rate: Some(fx),
        }],
        SplitRule::Equal {
            participants: vec!["C".to_string(), "D".to_string()],
        },
        "错误汇率折算",
        "",
        "initial",
        vec![],
        false,
    );
    assert!(matches!(bad_res, Err(CoreError::FinancialValidation(_))));
}

#[test]
fn test_m2_four_settlement_modes_and_debt_novation_lifecycle() {
    // Reproduces the exact PRD Section 12.6 worked example (in minor units: 1 yuan/dollar = 100 cents):
    // Bill 1 (CNY): 1000.00 CNY (100_000), A pays 600.00 (60_000), B pays 400.00 (40_000), A/B/C/D share 250.00 (25_000) each.
    // Bill 2 (USD): 100.00 USD (10_000), C pays 100.00 (10_000), A/B/C/D share 25.00 (2_500) each.
    // Settlement FX: 1 USD = 7 CNY.
    let (mut node_a, mut node_b, mut node_c, mut node_d) = setup_four_member_group();

    node_a
        .submit_expense_revision(
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
            "酒店住宿",
            "",
            "create",
            vec![],
            false,
        )
        .unwrap();

    node_c
        .submit_expense_revision(
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
            "餐厅晚餐",
            "",
            "create",
            vec![],
            false,
        )
        .unwrap();

    // Sync all nodes over LAN
    node_a.sync_lan_with_peer(&mut node_c).unwrap();
    node_a.sync_lan_with_peer(&mut node_b).unwrap();
    node_a.sync_lan_with_peer(&mut node_d).unwrap();

    let fx_rates = vec![FxRateSpec::new("USD", "CNY", 7, 1).unwrap()];

    // AC-S01: Verify transfer counts across all 4 modes: 8, 6, 6, 3
    let p_by_curr_pair = node_a
        .preview_settlement(SettlementMode::ByCurrencyPairwise, None, &[])
        .unwrap();
    let p_by_curr_min = node_a
        .preview_settlement(SettlementMode::ByCurrencyMinTransfers, None, &[])
        .unwrap();
    let p_merged_pair = node_a
        .preview_settlement(
            SettlementMode::MergedCurrencyPairwise,
            Some("CNY"),
            &fx_rates,
        )
        .unwrap();
    let p_merged_min = node_a
        .preview_settlement(
            SettlementMode::MergedCurrencyMinTransfers,
            Some("CNY"),
            &fx_rates,
        )
        .unwrap();

    assert_eq!(p_by_curr_pair.transfers.len(), 8);
    assert_eq!(p_by_curr_min.transfers.len(), 6);
    assert_eq!(p_merged_pair.transfers.len(), 6);
    assert_eq!(p_merged_min.transfers.len(), 3);
    assert_eq!(p_merged_min.optimality, OptimalityStatus::ProvenOptimal);

    // AC-S02: Verify exact transfers in MergedCurrencyMinTransfers:
    // B -> A: 25.00 CNY (2_500), D -> A: 150.00 CNY (15_000), D -> C: 275.00 CNY (27_500)
    assert_eq!(
        p_merged_min.transfers,
        vec![
            TransferEdge {
                debtor_id: "B".to_string(),
                creditor_id: "A".to_string(),
                currency: "CNY".to_string(),
                amount_minor: 2_500,
            },
            TransferEdge {
                debtor_id: "D".to_string(),
                creditor_id: "A".to_string(),
                currency: "CNY".to_string(),
                amount_minor: 15_000,
            },
            TransferEdge {
                debtor_id: "D".to_string(),
                creditor_id: "C".to_string(),
                currency: "CNY".to_string(),
                amount_minor: 27_500,
            },
        ]
    );

    // Propose formal settlement snapshot
    node_a
        .propose_settlement_snapshot(
            "snap_1",
            SettlementMode::MergedCurrencyMinTransfers,
            Some("CNY"),
            fx_rates.clone(),
        )
        .unwrap();

    // AC-S07: Cannot commit before all affected members approve
    assert!(node_a.commit_settlement_snapshot("snap_1").is_err());

    // Sync proposal to B, C, D and collect their approvals
    node_a.sync_lan_with_peer(&mut node_b).unwrap();
    node_a.sync_lan_with_peer(&mut node_c).unwrap();
    node_a.sync_lan_with_peer(&mut node_d).unwrap();

    node_a.approve_settlement_snapshot("snap_1").unwrap();
    node_b.approve_settlement_snapshot("snap_1").unwrap();
    node_c.approve_settlement_snapshot("snap_1").unwrap();
    node_d.approve_settlement_snapshot("snap_1").unwrap();

    node_a.sync_lan_with_peer(&mut node_b).unwrap();
    node_a.sync_lan_with_peer(&mut node_c).unwrap();
    node_a.sync_lan_with_peer(&mut node_d).unwrap();

    // Commit snapshot (Debt Novation takes effect)
    node_a.commit_settlement_snapshot("snap_1").unwrap();
    node_a.sync_lan_with_peer(&mut node_b).unwrap();
    node_a.sync_lan_with_peer(&mut node_c).unwrap();
    node_a.sync_lan_with_peer(&mut node_d).unwrap();

    let proj = node_a.repo.project_group(&node_a.group_id).unwrap();
    assert_eq!(proj.active_obligations.len(), 3);
    let ob_list: Vec<SettlementObligation> = proj.active_obligations.values().cloned().collect();

    // AC-P01: B declares paying A 25.00 CNY; before A confirms, obligation is still open
    let decl_b = node_b
        .declare_repayment(
            "pay_b_a",
            "B",
            "A",
            "CNY",
            2_500,
            Some(ob_list[0].obligation_id.clone()),
            "已微信转账25元",
        )
        .unwrap();
    node_a.sync_lan_with_peer(&mut node_b).unwrap();

    let proj_before_confirm = node_a.repo.project_group(&node_a.group_id).unwrap();
    assert_eq!(
        proj_before_confirm.repayments["pay_b_a"].status,
        RepaymentStatus::DeclaredByPayer
    );
    assert_eq!(
        proj_before_confirm.active_obligations[&ob_list[0].obligation_id].remaining_minor(),
        2_500
    );

    // Non-payee (B) cannot confirm receipt of payment!
    assert!(node_b
        .confirm_repayment("pay_b_a", &decl_b.event_id, None)
        .is_err());

    // Payee A confirms B's payment, D pays A and C and both confirm
    node_a
        .confirm_repayment("pay_b_a", &decl_b.event_id, None)
        .unwrap();

    let decl_d_a = node_d
        .declare_repayment(
            "pay_d_a",
            "D",
            "A",
            "CNY",
            15_000,
            Some(ob_list[1].obligation_id.clone()),
            "支付宝转150元",
        )
        .unwrap();
    let decl_d_c = node_d
        .declare_repayment(
            "pay_d_c",
            "D",
            "C",
            "CNY",
            27_500,
            Some(ob_list[2].obligation_id.clone()),
            "支付宝转275元",
        )
        .unwrap();
    node_a.sync_lan_with_peer(&mut node_d).unwrap();
    node_c.sync_lan_with_peer(&mut node_d).unwrap();

    node_a
        .confirm_repayment("pay_d_a", &decl_d_a.event_id, None)
        .unwrap();
    node_c
        .confirm_repayment("pay_d_c", &decl_d_c.event_id, None)
        .unwrap();
    node_a.sync_lan_with_peer(&mut node_c).unwrap();

    // AC-S08 & AC-S09: Once all novated obligations are paid, switching back to ByCurrencyPairwise
    // or any other mode MUST NOT resurrect old USD/CNY debts or cycles!
    for mode in [
        SettlementMode::ByCurrencyPairwise,
        SettlementMode::ByCurrencyMinTransfers,
        SettlementMode::MergedCurrencyPairwise,
        SettlementMode::MergedCurrencyMinTransfers,
    ] {
        let preview = node_a
            .preview_settlement(mode, Some("CNY"), &fx_rates)
            .unwrap();
        assert!(
            preview.transfers.is_empty(),
            "mode {mode:?} resurrected residual transfers: {:?}",
            preview.transfers
        );
    }

    // AC-S10: If FinanceEditor B later amends the already-settled hotel bill from 1,000 CNY to 1,200 CNY (+200 CNY paid by A),
    // only the +200 CNY delta (C owes A 50, D owes A 50, B owes A 50) enters the new open ledger!
    node_a.sync_lan_with_peer(&mut node_b).unwrap();
    let settled_hotel_rev_id = node_b
        .repo
        .project_group(&node_b.group_id)
        .unwrap()
        .expenses["exp_hotel_cny"]
        .active_revision_event_id
        .clone()
        .unwrap();

    node_b
        .submit_expense_revision(
            "exp_hotel_cny",
            vec![settled_hotel_rev_id],
            "CNY",
            120_000,
            vec![
                PayerContribution {
                    participant_id: "A".to_string(),
                    amount_minor: 80_000, // +200.00 CNY
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
            "酒店住宿（含加床费）",
            "",
            "补记200元加床费",
            vec![],
            false,
        )
        .unwrap();

    let delta_preview = node_b
        .preview_settlement(SettlementMode::ByCurrencyMinTransfers, None, &[])
        .unwrap();
    assert_eq!(delta_preview.net_balances_by_currency["CNY"]["A"], 15_000);
    assert_eq!(delta_preview.net_balances_by_currency["CNY"]["B"], -5_000);
    assert_eq!(delta_preview.net_balances_by_currency["CNY"]["C"], -5_000);
    assert_eq!(delta_preview.net_balances_by_currency["CNY"]["D"], -5_000);
}

#[test]
fn test_m2_exact_bitmask_dp_beats_greedy_counterexample_ac_s04() {
    // AC-S04: 6 participants with two disjoint zero-sum subsets:
    // Subset 1: D1(-600), C1(+300), C2(+300) -> 2 transfers
    // Subset 2: D2(-400), D3(-400), C3(+800) -> 2 transfers
    // Naive greedy pairs largest debtor D1(-600) with largest creditor C3(+800), resulting in 5 transfers.
    // Exact Bitmask DP partitions into 2 zero-sum subsets and achieves the proven minimum of 4 transfers.
    let balances: BTreeMap<String, i64> = [
        ("D1".to_string(), -600),
        ("D2".to_string(), -400),
        ("D3".to_string(), -400),
        ("C1".to_string(), 300),
        ("C2".to_string(), 300),
        ("C3".to_string(), 800),
    ]
    .into_iter()
    .collect();

    let (edges, opt) = solve_min_transfers_single_currency("CNY", &balances).unwrap();
    assert_eq!(opt, OptimalityStatus::ProvenOptimal);
    assert_eq!(edges.len(), 4);
}

#[test]
fn test_m2_permissions_concurrent_conflicts_and_offline_revocation() {
    let (mut node_a, mut node_b, mut node_c, _) = setup_four_member_group();

    // A creates expense V1
    let v1 = node_a
        .submit_expense_revision(
            "exp_ticket",
            vec![],
            "CNY",
            40_000,
            vec![PayerContribution {
                participant_id: "A".to_string(),
                amount_minor: 40_000,
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
            "门票",
            "",
            "create",
            vec![],
            false,
        )
        .unwrap();

    node_a.sync_lan_with_peer(&mut node_b).unwrap();
    node_a.sync_lan_with_peer(&mut node_c).unwrap();

    // AC-A02: Ordinary member C cannot edit A's expense
    let err = node_c
        .submit_expense_revision(
            "exp_ticket",
            vec![v1.event_id.clone()],
            "CNY",
            50_000,
            vec![PayerContribution {
                participant_id: "A".to_string(),
                amount_minor: 50_000,
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
            "门票篡改",
            "",
            "unauthorized edit",
            vec![],
            false,
        )
        .unwrap_err();
    assert!(matches!(err, CoreError::PermissionDenied { .. }));

    // AC-C01: A (creator) and B (FinanceEditor) concurrently edit V1 while offline -> V2a and V2b
    let v2a = node_a
        .submit_expense_revision(
            "exp_ticket",
            vec![v1.event_id.clone()],
            "CNY",
            44_000,
            vec![PayerContribution {
                participant_id: "A".to_string(),
                amount_minor: 44_000,
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
            "门票(A改)",
            "",
            "A离线修改",
            vec![],
            false,
        )
        .unwrap();

    let v2b = node_b
        .submit_expense_revision(
            "exp_ticket",
            vec![v1.event_id.clone()],
            "CNY",
            48_000,
            vec![PayerContribution {
                participant_id: "A".to_string(),
                amount_minor: 48_000,
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
            "门票(B改)",
            "",
            "B离线修改",
            vec![],
            false,
        )
        .unwrap();

    node_a.sync_lan_with_peer(&mut node_b).unwrap();
    let proj_conflict = node_a.repo.project_group(&node_a.group_id).unwrap();
    assert!(proj_conflict.expenses["exp_ticket"].has_conflict);
    assert_eq!(
        proj_conflict.expenses["exp_ticket"]
            .conflict_leaf_event_ids
            .len(),
        2
    );

    // AC-S12: Unresolved conflict blocks proposing formal settlement
    assert!(matches!(
        node_a.propose_settlement_snapshot("snap_blocked", SettlementMode::ByCurrencyPairwise, None, vec![]),
        Err(CoreError::Conflict(_))
    ));

    // AC-C02: FinanceEditor B resolves conflict by referencing both [v2a, v2b]
    let v3_resolved = node_b
        .submit_expense_revision(
            "exp_ticket",
            vec![v2a.event_id.clone(), v2b.event_id.clone()],
            "CNY",
            46_000,
            vec![PayerContribution {
                participant_id: "A".to_string(),
                amount_minor: 46_000,
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
            "门票(合并确认)",
            "",
            "合并A与B分支",
            vec![],
            false,
        )
        .unwrap();

    node_a.sync_lan_with_peer(&mut node_b).unwrap();
    let proj_resolved = node_a.repo.project_group(&node_a.group_id).unwrap();
    assert!(!proj_resolved.expenses["exp_ticket"].has_conflict);
    assert_eq!(
        proj_resolved.expenses["exp_ticket"]
            .active_revision_event_id
            .as_deref(),
        Some(v3_resolved.event_id.as_str())
    );

    // AC-A03: Owner A revokes B's FinanceEditor role -> Member, setting accepted checkpoint for dev_b to seq=2.
    // Meanwhile B (still offline on Policy V1) makes another edit (seq=3) to A's bill.
    let mut new_pol = proj_resolved.active_policy.clone();
    new_pol.policy_seq = 2;
    new_pol.previous_policy_event_id = Some(proj_resolved.active_policy_event_id.clone());
    new_pol.participants.get_mut("B").unwrap().role = Role::Member;
    new_pol
        .accepted_device_checkpoints
        .insert("dev_b".to_string(), 2);
    node_a.submit_policy_update(new_pol).unwrap();

    let b_offline_edit = node_b
        .submit_expense_revision(
            "exp_ticket",
            vec![v3_resolved.event_id.clone()],
            "CNY",
            52_000,
            vec![PayerContribution {
                participant_id: "A".to_string(),
                amount_minor: 52_000,
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
            "B撤权后离线编辑",
            "",
            "offline edit under old policy",
            vec![],
            false,
        )
        .unwrap();

    node_a.sync_lan_with_peer(&mut node_b).unwrap();
    let proj_after_revoke = node_a.repo.project_group(&node_a.group_id).unwrap();
    assert!(proj_after_revoke
        .pending_reauth_events
        .contains(&b_offline_edit.event_id));
    assert_eq!(
        proj_after_revoke.expenses["exp_ticket"]
            .active_revision_event_id
            .as_deref(),
        Some(v3_resolved.event_id.as_str())
    );
}

#[test]
fn test_m3_webdav_tripdelta_optical_fountain_and_out_of_order_convergence() {
    let (mut node_a, mut node_b, mut node_c, _) = setup_four_member_group();

    // A creates 3 sequential expenses on dev_a (seq 2, 3, 4)
    let mut a_events = Vec::new();
    for i in 1..=3 {
        let ev = node_a
            .submit_expense_revision(
                &format!("exp_{i}"),
                vec![],
                "CNY",
                12_000 * i,
                vec![PayerContribution {
                    participant_id: "A".to_string(),
                    amount_minor: 12_000 * i,
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
                &format!("账单{i}"),
                "",
                "create",
                vec![],
                false,
            )
            .unwrap();
        a_events.push(ev);
    }

    // AC-L04: B receives event #3 (seq 4) out of order while missing seq 2 and seq 3
    let status = node_b
        .repo
        .append_signed_event(&a_events[2], Some(&node_b.cipher))
        .unwrap();
    assert_eq!(status, EventApplyStatus::PendingDependency);

    let b_summary = node_b.repo.build_sync_summary(&node_b.group_id).unwrap();
    assert_eq!(b_summary.device_cursors["dev_a"].contiguous_seq, 1);
    assert_eq!(b_summary.device_cursors["dev_a"].missing_seqs, vec![2, 3]);

    // When A computes missing events for B, it selects exactly seq 2 and seq 3 (not seq 1 or seq 4)!
    let missing_for_b = node_a
        .repo
        .select_events_missing_on_peer(&node_a.group_id, &b_summary)
        .unwrap();
    assert_eq!(missing_for_b.len(), 2);
    assert_eq!(missing_for_b[0].unsigned.sequence, 2);
    assert_eq!(missing_for_b[1].unsigned.sequence, 3);

    // AC-Q01..Q03: Transmit `missing_for_b` via Optical Fountain QR frames,
    // starting mid-stream and dropping 2 direct source frames, recovering via parity frames!
    let pkg =
        TripDeltaPackage::pack_events(&node_a.group_id, &missing_for_b, &node_a.cipher).unwrap();
    let frames = encode_optical_fountain_frames(&pkg, 180, 12).unwrap();
    assert!(frames.len() > 4);

    let mut assembler = OpticalFountainAssembler::new();
    let mut recovered_pkg = None;
    // Start mid-stream at frame 2, skipping frame 0 and frame 1, then wrap around from frame 2..end
    for frame in frames.iter().skip(2) {
        if let Some(done) = assembler.ingest_frame(frame).unwrap() {
            recovered_pkg = Some(done);
            break;
        }
    }
    let recovered = recovered_pkg.expect("fountain parity frames should recover dropped source frames");
    let imported = node_b
        .import_tripdelta_bytes(&recovered.to_bytes().unwrap())
        .unwrap();
    assert_eq!(imported.added_count, 2);
    assert_eq!(imported.pending_dependency_count, 0);

    // AC-D01, AC-D02, AC-D05: WebDAV async sync between B and C, including server-side tampering detection
    let mut webdav = InMemoryWebDavStore::new();
    let up_report =
        sync_with_webdav(&mut node_b.repo, &node_b.group_id, &node_b.cipher, &mut webdav).unwrap();
    assert_eq!(up_report.uploaded_objects, 4); // genesis + 3 expenses

    // Tamper with one object on the WebDAV server and add a bogus object
    let dir = opaque_group_directory_id(&node_b.group_id);
    webdav
        .put_encrypted_object(&dir, "bogus_hash", b"corrupted_bytes")
        .unwrap();

    let down_report =
        sync_with_webdav(&mut node_c.repo, &node_c.group_id, &node_c.cipher, &mut webdav).unwrap();
    assert_eq!(down_report.downloaded_events, 3);
    assert_eq!(down_report.tampered_or_rejected_objects, 1);

    // AC-B03: Verify A, B, and C have 100% identical projections and open balances regardless of arrival order
    let all_ev = node_a.repo.list_events(&node_a.group_id).unwrap();
    let mut reversed_ev = all_ev.clone();
    reversed_ev.reverse();

    let proj_forward = build_projection(&node_a.group_id, &all_ev).unwrap();
    let proj_reverse = build_projection(&node_a.group_id, &reversed_ev).unwrap();
    let proj_b = node_b.repo.project_group(&node_b.group_id).unwrap();
    let proj_c = node_c.repo.project_group(&node_c.group_id).unwrap();

    assert_eq!(
        proj_forward.open_pair_debts_with_history(&all_ev).unwrap(),
        proj_reverse
            .open_pair_debts_with_history(&reversed_ev)
            .unwrap()
    );
    assert_eq!(
        proj_forward.open_pair_debts_with_history(&all_ev).unwrap(),
        proj_b.open_pair_debts_with_history(&all_ev).unwrap()
    );
    assert_eq!(
        proj_forward.open_pair_debts_with_history(&all_ev).unwrap(),
        proj_c.open_pair_debts_with_history(&all_ev).unwrap()
    );
}

#[test]
fn test_m2_overpayment_late_repayment_mapping_and_unbound_participant_ac_p03_p06_g02() {
    let (mut node_a, mut node_b, _, _) = setup_four_member_group();

    // B owes A 100.00 CNY (10_000 fen)
    node_a
        .submit_expense_revision(
            "exp_taxi",
            vec![],
            "CNY",
            20_000,
            vec![PayerContribution {
                participant_id: "A".to_string(),
                amount_minor: 20_000,
                original_currency: None,
                original_amount_minor: None,
                frozen_fx_rate: None,
            }],
            SplitRule::Equal {
                participants: vec!["A".to_string(), "B".to_string()],
            },
            "打车",
            "",
            "create",
            vec![],
            false,
        )
        .unwrap();
    node_a.sync_lan_with_peer(&mut node_b).unwrap();

    // Propose, approve, and commit snap_r1 (B -> A: 10_000 fen)
    node_a
        .propose_settlement_snapshot("snap_r1", SettlementMode::ByCurrencyPairwise, None, vec![])
        .unwrap();
    node_a.sync_lan_with_peer(&mut node_b).unwrap();
    node_a.approve_settlement_snapshot("snap_r1").unwrap();
    node_b.approve_settlement_snapshot("snap_r1").unwrap();
    node_a.sync_lan_with_peer(&mut node_b).unwrap();
    node_a.commit_settlement_snapshot("snap_r1").unwrap();
    node_a.sync_lan_with_peer(&mut node_b).unwrap();

    let ob_r1 = node_a
        .repo
        .project_group(&node_a.group_id)
        .unwrap()
        .active_obligations
        .values()
        .next()
        .unwrap()
        .obligation_id
        .clone();

    // Before B's payment against ob_r1 is confirmed, another expense is added (+60.00 CNY -> B owes A another 30.00 CNY)
    // and snap_r2 novates ob_r1 into ob_r2 (total 130.00 CNY = 13_000 fen)
    node_a
        .submit_expense_revision(
            "exp_coffee",
            vec![],
            "CNY",
            6_000,
            vec![PayerContribution {
                participant_id: "A".to_string(),
                amount_minor: 6_000,
                original_currency: None,
                original_amount_minor: None,
                frozen_fx_rate: None,
            }],
            SplitRule::Equal {
                participants: vec!["A".to_string(), "B".to_string()],
            },
            "咖啡",
            "",
            "create",
            vec![],
            false,
        )
        .unwrap();
    node_a.sync_lan_with_peer(&mut node_b).unwrap();

    node_a
        .propose_settlement_snapshot("snap_r2", SettlementMode::ByCurrencyPairwise, None, vec![])
        .unwrap();
    node_a.sync_lan_with_peer(&mut node_b).unwrap();
    node_a.approve_settlement_snapshot("snap_r2").unwrap();
    node_b.approve_settlement_snapshot("snap_r2").unwrap();
    node_a.sync_lan_with_peer(&mut node_b).unwrap();
    node_a.commit_settlement_snapshot("snap_r2").unwrap();
    node_a.sync_lan_with_peer(&mut node_b).unwrap();

    let ob_r2 = node_a
        .repo
        .project_group(&node_a.group_id)
        .unwrap()
        .active_obligations
        .values()
        .next()
        .unwrap()
        .obligation_id
        .clone();

    // AC-P06 & AC-P03: B declares a late payment referencing already-novated `ob_r1`,
    // and actually overpays 150.00 CNY (15_000 fen vs 13_000 fen owed on ob_r2)!
    let late_decl = node_b
        .declare_repayment(
            "pay_late_over",
            "B",
            "A",
            "CNY",
            15_000,
            Some(ob_r1),
            "转了150元整",
        )
        .unwrap();
    node_a.sync_lan_with_peer(&mut node_b).unwrap();
    node_a
        .confirm_repayment(
            "pay_late_over",
            &late_decl.event_id,
            Some("RefundNeeded".to_string()),
        )
        .unwrap();

    // Because `ob_r1` was already novated, the confirmed payment enters `PendingMapping`
    // and blocks proposing a new settlement until mapped (AC-P06, AC-S12).
    let proj_pending = node_a.repo.project_group(&node_a.group_id).unwrap();
    assert_eq!(
        proj_pending.repayments["pay_late_over"].status,
        RepaymentStatus::PendingMapping
    );
    assert!(node_a
        .propose_settlement_snapshot("snap_blocked_map", SettlementMode::ByCurrencyPairwise, None, vec![])
        .is_err());

    // Map the late payment to `ob_r2` -> `ob_r2` (13_000) is fully paid, and 2_000 fen overpayment
    // creates a reverse credit (A now owes B 20.00 CNY = 2_000 fen, AC-P03)!
    node_a
        .map_late_repayment("pay_late_over", &ob_r2, "映射到最新结算义务ob_r2")
        .unwrap();
    let preview_after_overpay = node_a
        .preview_settlement(SettlementMode::ByCurrencyPairwise, None, &[])
        .unwrap();
    assert_eq!(
        preview_after_overpay.transfers,
        vec![TransferEdge {
            debtor_id: "A".to_string(),
            creditor_id: "B".to_string(),
            currency: "CNY".to_string(),
            amount_minor: 2_000,
        }]
    );
}

#[test]
fn test_m4_ffi_closed_loop_workflow() {
    use sbill_core::ffi::{dispatch_ffi_json_on_session, FfiResponse, WorkspaceSession};

    let mut session = WorkspaceSession::new_with_sample_trip().unwrap();
    let mut dispatch = |cmd: &str| dispatch_ffi_json_on_session(&mut session, cmd);

    // 1. Initialize workspace snapshot via FFI JSON
    let init_raw = dispatch(r#"{"op":"InitOrGetSnapshot"}"#);
    let init_resp: FfiResponse = serde_json::from_str(&init_raw).unwrap();
    assert!(init_resp.ok);
    let snap = init_resp.snapshot.unwrap();
    assert_eq!(snap.expenses.len(), 2);
    assert_eq!(snap.conflict_count, 0);

    // 2. Simulate concurrent offline edits on `exp_hotel_cny` -> creates conflict branches
    let conflict_raw = dispatch(
        r#"{"op":"SimulateConcurrentConflict","args":{"expense_id":"exp_hotel_cny"}}"#,
    );
    let conflict_resp: FfiResponse = serde_json::from_str(&conflict_raw).unwrap();
    assert!(conflict_resp.ok);
    let snap_c = conflict_resp.snapshot.unwrap();
    assert_eq!(snap_c.conflict_count, 1);
    let hotel = snap_c
        .expenses
        .iter()
        .find(|e| e.expense_id == "exp_hotel_cny")
        .unwrap();
    assert!(hotel.has_conflict);
    assert_eq!(hotel.conflict_branches.len(), 2);

    // 3. FinanceEditor B resolves the conflict via UpsertExpense referencing both conflict branch event IDs
    let parent_ids: Vec<String> = hotel
        .conflict_branches
        .iter()
        .map(|b| b.event_id.clone())
        .collect();
    let resolve_cmd = serde_json::json!({
        "op": "UpsertExpense",
        "args": {
            "actor_id": "B",
            "expense_id": "exp_hotel_cny",
            "parent_revision_event_ids": parent_ids,
            "currency": "CNY",
            "total_minor": 112000,
            "payers": [
                {"participant_id": "A", "amount_minor": 72000, "original_currency": null, "original_amount_minor": null, "frozen_fx_rate": null},
                {"participant_id": "B", "amount_minor": 40000, "original_currency": null, "original_amount_minor": null, "frozen_fx_rate": null}
            ],
            "split_rule": {"Equal": {"participants": ["A", "B", "C", "D"]}},
            "title": "温泉酒店两晚合住 (已解决冲突)",
            "note": "管理员合并确认最终金额 1,120.00 元",
            "revision_reason": "合并创建人小费与管理员核对金额",
            "voided": false
        }
    });
    let resolve_raw = dispatch(&resolve_cmd.to_string());
    let resolve_resp: FfiResponse = serde_json::from_str(&resolve_raw).unwrap();
    assert!(resolve_resp.ok);
    let snap_r = resolve_resp.snapshot.unwrap();
    assert_eq!(snap_r.conflict_count, 0);
}

#[test]
fn test_m5_settlement_center_ffi_lifecycle() {
    use sbill_core::ffi::{dispatch_ffi_json_on_session, FfiResponse, WorkspaceSession};

    let mut session = WorkspaceSession::new_with_sample_trip().unwrap();
    let mut dispatch = |cmd: &str| dispatch_ffi_json_on_session(&mut session, cmd);

    // 1. Reset demo workspace to clean PRD Section 12.6 baseline
    let reset_raw = dispatch(r#"{"op":"ResetDemoWorkspace"}"#);
    let reset_resp: FfiResponse = serde_json::from_str(&reset_raw).unwrap();
    assert!(reset_resp.ok);
    let snap = reset_resp.snapshot.unwrap();

    assert_eq!(
        snap.settlement_previews["ByCurrencyPairwise"]
            .transfers
            .len(),
        8
    );
    assert_eq!(
        snap.settlement_previews["ByCurrencyMinTransfers"]
            .transfers
            .len(),
        6
    );
    assert_eq!(
        snap.settlement_previews["MergedCurrencyPairwise"]
            .transfers
            .len(),
        6
    );
    assert_eq!(
        snap.settlement_previews["MergedCurrencyMinTransfers"]
            .transfers
            .len(),
        3
    );

    // 2. Test SetFxRate via FFI (change USD->CNY to 8, then restore to 7)
    let fx8_raw = dispatch(
        r#"{"op":"SetFxRate","args":{"base_currency":"USD","quote_currency":"CNY","numerator":8,"denominator":1}}"#,
    );
    let fx8_resp: FfiResponse = serde_json::from_str(&fx8_raw).unwrap();
    assert!(fx8_resp.ok);
    assert_eq!(
        fx8_resp.snapshot.unwrap().settlement_previews["MergedCurrencyMinTransfers"]
            .net_balances_by_currency["CNY"]["C"],
        35_000
    );

    let fx7_raw = dispatch(
        r#"{"op":"SetFxRate","args":{"base_currency":"USD","quote_currency":"CNY","numerator":7,"denominator":1}}"#,
    );
    assert!(serde_json::from_str::<FfiResponse>(&fx7_raw).unwrap().ok);

    // 3. Propose MergedCurrencyMinTransfers snapshot via FFI
    let prop_raw = dispatch(
        r#"{"op":"ProposeSettlement","args":{"actor_id":"A","snapshot_id":"snap_m5_1","mode":"MergedCurrencyMinTransfers","settlement_currency":"CNY"}}"#,
    );
    let prop_resp: FfiResponse = serde_json::from_str(&prop_raw).unwrap();
    assert!(prop_resp.ok);
    assert_eq!(prop_resp.snapshot.unwrap().snapshots.len(), 1);

    // 4. Premature commit before all approvals must fail (AC-S07)
    let early_commit_raw = dispatch(
        r#"{"op":"CommitSettlement","args":{"actor_id":"A","snapshot_id":"snap_m5_1"}}"#,
    );
    let early_commit_resp: FfiResponse = serde_json::from_str(&early_commit_raw).unwrap();
    assert!(!early_commit_resp.ok);

    // 5. All 4 affected participants sign approval via FFI
    for member in ["A", "B", "C", "D"] {
        let app_cmd = serde_json::json!({
            "op": "ApproveSettlement",
            "args": {
                "actor_id": member,
                "snapshot_id": "snap_m5_1"
            }
        });
        let app_resp: FfiResponse =
            serde_json::from_str(&dispatch(&app_cmd.to_string())).unwrap();
        assert!(app_resp.ok);
    }

    // 6. Coordinator A commits snapshot -> executes Debt Novation into 3 obligations
    let commit_raw = dispatch(
        r#"{"op":"CommitSettlement","args":{"actor_id":"A","snapshot_id":"snap_m5_1"}}"#,
    );
    let commit_resp: FfiResponse = serde_json::from_str(&commit_raw).unwrap();
    assert!(commit_resp.ok);
    let committed_snap = commit_resp.snapshot.unwrap();
    assert_eq!(committed_snap.active_obligations.len(), 3);

    // 7. Fulfill all 3 novated obligations and confirm receipts
    for (idx, ob) in committed_snap.active_obligations.iter().enumerate() {
        let pay_id = format!("pay_m5_{idx}");
        let decl_cmd = serde_json::json!({
            "op": "DeclareRepayment",
            "args": {
                "actor_id": ob.debtor_id,
                "payment_id": pay_id,
                "payer_id": ob.debtor_id,
                "payee_id": ob.creditor_id,
                "currency": ob.currency,
                "amount_minor": ob.total_amount_minor,
                "target_obligation_id": ob.obligation_id,
                "note": "履行M5结算快照义务"
            }
        });
        let decl_resp: FfiResponse =
            serde_json::from_str(&dispatch(&decl_cmd.to_string())).unwrap();
        assert!(decl_resp.ok);
        let decl_ev_id = decl_resp
            .snapshot
            .unwrap()
            .repayments
            .iter()
            .find(|r| r.payment_id == pay_id)
            .unwrap()
            .declare_event_id
            .clone();

        let conf_cmd = serde_json::json!({
            "op": "ConfirmRepayment",
            "args": {
                "actor_id": ob.creditor_id,
                "payment_id": pay_id,
                "declare_event_id": decl_ev_id,
                "overpayment_policy": null
            }
        });
        let conf_resp: FfiResponse =
            serde_json::from_str(&dispatch(&conf_cmd.to_string())).unwrap();
        assert!(conf_resp.ok);
    }

    // 8. Verify zero residual transfers across ALL 4 settlement modes (AC-S08, AC-S09)
    let final_raw = dispatch(r#"{"op":"InitOrGetSnapshot"}"#);
    let final_snap = serde_json::from_str::<FfiResponse>(&final_raw)
        .unwrap()
        .snapshot
        .unwrap();
    for (mode_key, preview) in &final_snap.settlement_previews {
        assert!(
            preview.transfers.is_empty(),
            "mode {mode_key} had residual transfers after full debt novation repayment: {:?}",
            preview.transfers
        );
    }
}

#[test]
fn test_m6_tripdelta_exchange_and_webdav_ffi_lifecycle() {
    use sbill_core::ffi::{dispatch_ffi_json_on_session, FfiResponse, WorkspaceSession};

    let mut session = WorkspaceSession::new_with_sample_trip().unwrap();
    let mut dispatch = |cmd: &str| dispatch_ffi_json_on_session(&mut session, cmd);

    // 1. Reset demo workspace
    let reset_raw = dispatch(r#"{"op":"ResetDemoWorkspace"}"#);
    let reset_snap = serde_json::from_str::<FfiResponse>(&reset_raw)
        .unwrap()
        .snapshot
        .unwrap();
    assert_eq!(reset_snap.expenses.len(), 2);
    assert_eq!(reset_snap.webdav_status.pending_upload_count, 3);

    // 2. Export .tripdelta package and compact SBILL1: code
    let exp_raw = dispatch(r#"{"op":"ExportTripDelta"}"#);
    let exp_resp: FfiResponse = serde_json::from_str(&exp_raw).unwrap();
    assert!(exp_resp.ok);
    let rep = exp_resp
        .snapshot
        .unwrap()
        .last_sync_report
        .expect("export report must be present");
    let compact_code = rep.exported_compact_code.clone().unwrap();
    assert!(compact_code.starts_with("SBILL1:"));

    // 3. Re-importing the exact same compact code is 100% idempotent (AC-F01)
    let imp_cmd = serde_json::json!({
        "op": "ImportTripDelta",
        "args": { "payload": compact_code }
    });
    let imp_resp: FfiResponse =
        serde_json::from_str(&dispatch(&imp_cmd.to_string())).unwrap();
    assert!(imp_resp.ok);
    let imp_rep = imp_resp.snapshot.unwrap().last_sync_report.unwrap();
    assert_eq!(imp_rep.added_events, 0);
    assert_eq!(imp_rep.duplicate_events, 3);

    // 4. Truncated or corrupted .tripdelta input is rejected (AC-F02)
    let bad_imp_raw = dispatch(
        r#"{"op":"ImportTripDelta","args":{"payload":"SBILL1:corrupted_truncated"}}"#,
    );
    assert!(!serde_json::from_str::<FfiResponse>(&bad_imp_raw).unwrap().ok);

    // 5. Simulate peer D sending a new .tripdelta incremental package -> adds 1 new expense
    let peer_raw = dispatch(
        r#"{"op":"SimulatePeerTripDelta","args":{"auto_import":true}}"#,
    );
    let peer_snap = serde_json::from_str::<FfiResponse>(&peer_raw)
        .unwrap()
        .snapshot
        .unwrap();
    assert_eq!(peer_snap.expenses.len(), 3);
    assert_eq!(peer_snap.last_sync_report.unwrap().added_events, 1);

    // 6. Configure WebDAV as unreachable (offline WAN simulation AC-D02/D03) -> outbox retained
    let cfg_off_raw = dispatch(
        r#"{"op":"ConfigureWebDav","args":{"endpoint_url":"https://nas.local:5006/webdav","username":"sbill_member","simulate_unreachable":true}}"#,
    );
    assert!(serde_json::from_str::<FfiResponse>(&cfg_off_raw).unwrap().ok);

    let sync_off_raw = dispatch(r#"{"op":"SyncWebDavNow"}"#);
    let sync_off_snap = serde_json::from_str::<FfiResponse>(&sync_off_raw)
        .unwrap()
        .snapshot
        .unwrap();
    assert_eq!(sync_off_snap.webdav_status.pending_upload_count, 4);
    assert_eq!(sync_off_snap.last_sync_report.unwrap().failed_uploads, 4);

    // 7. Restore WebDAV connectivity, simulate peer C uploading an async event + 1 tampered server object (AC-D01, AC-D05)
    let cfg_on_raw = dispatch(
        r#"{"op":"ConfigureWebDav","args":{"endpoint_url":"https://nas.local:5006/webdav","username":"sbill_member","simulate_unreachable":false}}"#,
    );
    assert!(serde_json::from_str::<FfiResponse>(&cfg_on_raw).unwrap().ok);

    let remote_inc_raw = dispatch(
        r#"{"op":"SimulateRemoteWebDavIncoming","args":{"inject_tampered":true}}"#,
    );
    assert!(serde_json::from_str::<FfiResponse>(&remote_inc_raw).unwrap().ok);

    let sync_on_raw = dispatch(r#"{"op":"SyncWebDavNow"}"#);
    let sync_on_snap = serde_json::from_str::<FfiResponse>(&sync_on_raw)
        .unwrap()
        .snapshot
        .unwrap();
    assert_eq!(sync_on_snap.webdav_status.pending_upload_count, 0);
    assert_eq!(sync_on_snap.expenses.len(), 4);
    let final_rep = sync_on_snap.last_sync_report.unwrap();
    assert_eq!(final_rep.uploaded_objects, 4);
    assert_eq!(final_rep.added_events, 1);
    assert_eq!(final_rep.rejected_or_tampered, 1);
}

#[test]
fn test_m7_lan_no_wan_gap_fill_and_optical_fountain_ffi_lifecycle() {
    use sbill_core::ffi::{dispatch_ffi_json_on_session, FfiResponse, WorkspaceSession};

    let mut session = WorkspaceSession::new_with_sample_trip().unwrap();
    let mut dispatch = |cmd: &str| dispatch_ffi_json_on_session(&mut session, cmd);

    let init_snap = serde_json::from_str::<FfiResponse>(&dispatch(r#"{"op":"InitOrGetSnapshot"}"#))
        .unwrap()
        .snapshot
        .unwrap();
    assert_eq!(init_snap.expenses.len(), 2);
    assert_eq!(init_snap.lan_status.discovered_peers.len(), 3);
    assert!(!init_snap.optical_session.outgoing_frames.is_empty());

    // 1. Simulate hotel AP client isolation (AC-L02) -> blocks direct LAN sync with clear diagnostic
    let ap_iso_raw = dispatch(
        r#"{"op":"ConfigureLanDiscovery","args":{"ap_isolation_detected":true}}"#,
    );
    let ap_iso_snap = serde_json::from_str::<FfiResponse>(&ap_iso_raw)
        .unwrap()
        .snapshot
        .unwrap();
    assert!(ap_iso_snap.lan_status.ap_isolation_detected);
    assert!(ap_iso_snap.lan_status.discovered_peers.is_empty());

    let blocked_lan_raw = dispatch(
        r#"{"op":"SyncLanWithPeer","args":{"peer_member_id":"B","simulate_gap_fill":true}}"#,
    );
    assert!(!serde_json::from_str::<FfiResponse>(&blocked_lan_raw).unwrap().ok);

    // 2. Restore LAN reachability (no WAN needed, AC-L01) and run gap-filling LAN sync (AC-L04)
    let ap_ok_raw = dispatch(
        r#"{"op":"ConfigureLanDiscovery","args":{"ap_isolation_detected":false}}"#,
    );
    assert!(serde_json::from_str::<FfiResponse>(&ap_ok_raw).unwrap().ok);

    let lan_sync_raw = dispatch(
        r#"{"op":"SyncLanWithPeer","args":{"peer_member_id":"B","simulate_gap_fill":true}}"#,
    );
    let lan_sync_snap = serde_json::from_str::<FfiResponse>(&lan_sync_raw)
        .unwrap()
        .snapshot
        .unwrap();
    assert_eq!(lan_sync_snap.expenses.len(), 4); // 2 initial + 2 gap-filled LAN expenses

    // 3. Switch optical transmitter to low-light/low-end slow mode (2 FPS, AC-Q05)
    let opt_gen_raw = dispatch(
        r#"{"op":"GenerateOpticalFrames","args":{"slice_byte_len":160,"parity_frames":8,"slow_mode":true}}"#,
    );
    let opt_gen_snap = serde_json::from_str::<FfiResponse>(&opt_gen_raw)
        .unwrap()
        .snapshot
        .unwrap();
    assert!(opt_gen_snap.optical_session.slow_mode);
    assert_eq!(opt_gen_snap.optical_session.recommended_fps, 2);

    // 4. Simulate airgapped optical fountain QR transfer starting mid-stream after dropping first 2 frames (AC-Q01..Q03)
    let airgap_raw = dispatch(
        r#"{"op":"SimulateOpticalAirgapTransfer","args":{"drop_first_two_frames":true}}"#,
    );
    let airgap_snap = serde_json::from_str::<FfiResponse>(&airgap_raw)
        .unwrap()
        .snapshot
        .unwrap();
    assert!(airgap_snap.optical_session.receiver_complete);
    assert_eq!(
        airgap_snap.optical_session.receiver_solved_slices,
        airgap_snap.optical_session.receiver_total_slices
    );
    assert_eq!(airgap_snap.expenses.len(), 5);
}






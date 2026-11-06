use sbill_core::{
    ffi::WorkspaceSession,
    workspace::{AppCommand, AppSnapshot, AppWorkspace},
};
use serde_json::{json, Value};
use std::path::PathBuf;

struct TestHome(PathBuf);
impl TestHome {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("sbill_workspace_{}", rand::random::<u128>()));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn db(&self) -> PathBuf {
        self.0.join("sbill_ledger_v1.sqlite3")
    }
    fn open(&self) -> AppWorkspace {
        AppWorkspace::open(self.db()).unwrap()
    }
}
impl Drop for TestHome {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).unwrap();
    }
}
fn call(app: &mut AppWorkspace, value: Value) -> AppSnapshot {
    app.execute(serde_json::from_value::<AppCommand>(value).unwrap())
        .unwrap()
}
fn fail(app: &mut AppWorkspace, value: Value) {
    assert!(app
        .execute(serde_json::from_value::<AppCommand>(value).unwrap())
        .is_err());
}
fn create(app: &mut AppWorkspace, companions: Vec<&str>) -> AppSnapshot {
    call(
        app,
        json!({"op":"AppCreateLedger","args":{"group_name":"真实出行","display_name":"我","companions":companions}}),
    )
}
fn ledger_call(app: &mut AppWorkspace, id: &str, command: Value) -> AppSnapshot {
    call(
        app,
        json!({"op":"AppLedgerCommand","args":{"group_id":id,"command":command}}),
    )
}
fn expense(actor: &str, participants: Vec<&str>, title: &str) -> Value {
    json!({"op":"UpsertExpense","args":{"actor_id":"forged_actor","expense_id":"client_id","parent_revision_event_ids":[],"currency":"CNY","total_minor":10000,
        "payers":[{"participant_id":actor,"amount_minor":10000,"original_currency":null,"original_amount_minor":null,"frozen_fx_rate":null}],
        "split_rule":{"Equal":{"participants":participants}},"title":title,"note":"","revision_reason":"create","voided":false}})
}

#[test]
fn empty_start_multi_ledger_isolation_and_restart() {
    let home = TestHome::new();
    let mut app = home.open();
    let empty = call(&mut app, json!({"op":"AppGet"}));
    assert!(empty.ledgers.is_empty());
    assert!(empty.active_ledger.is_none());
    let first = create(&mut app, vec!["伙伴"]);
    let ledger = first.active_ledger.unwrap();
    let id1 = ledger.group_id;
    let me1 = ledger.active_actor_id;
    assert!(ledger.expenses.is_empty());
    assert!(ledger.custom_categories.is_empty());
    assert_eq!(ledger.participants.len(), 2);
    assert_eq!(
        ledger
            .participants
            .iter()
            .filter(|p| p.bound_public_key.is_some())
            .count(),
        1
    );
    ledger_call(&mut app, &id1, expense(&me1, vec![&me1], "第一条账目"));
    ledger_call(
        &mut app,
        &id1,
        json!({"op":"AddCustomCategory","args":{"id":"same","icon":"🎿","name":"滑雪"}}),
    );
    ledger_call(
        &mut app,
        &id1,
        json!({"op":"SetFxRate","args":{"base_currency":"USD","quote_currency":"CNY","numerator":7,"denominator":1}}),
    );
    let second = create(&mut app, vec![]).active_ledger.unwrap();
    let id2 = second.group_id;
    assert_ne!(id1, id2);
    assert_ne!(me1, second.active_actor_id);
    assert!(second.expenses.is_empty());
    assert!(second.custom_categories.is_empty());
    assert!(second.default_fx_rates.is_empty());
    assert!(second.active_obligations.is_empty());
    assert!(second.snapshots.is_empty());
    fail(
        &mut app,
        json!({"op":"AppLedgerCommand","args":{"group_id":id1,"command":{"op":"AddCustomCategory","args":{"id":"stale","icon":"🛑","name":"错误账本"}}}}),
    );
    fail(
        &mut app,
        json!({"op":"AppAddParticipant","args":{"group_id":id1,"display_name":"错误伙伴","role":"Member"}}),
    );
    let back = call(
        &mut app,
        json!({"op":"AppSelectLedger","args":{"group_id":id1}}),
    )
    .active_ledger
    .unwrap();
    assert_eq!(back.expenses.len(), 1);
    assert_eq!(back.custom_categories.len(), 1);
    assert_eq!(back.default_fx_rates.len(), 1);
    let export = ledger_call(&mut app, &id1, json!({"op":"ExportTripDelta"}))
        .active_ledger
        .unwrap()
        .last_sync_report
        .unwrap()
        .exported_compact_code
        .unwrap();
    call(
        &mut app,
        json!({"op":"AppSelectLedger","args":{"group_id":id2}}),
    );
    fail(
        &mut app,
        json!({"op":"AppLedgerCommand","args":{"group_id":id2,"command":{"op":"ImportTripDelta","args":{"payload":export}}}}),
    );
    call(
        &mut app,
        json!({"op":"AppSelectLedger","args":{"group_id":id1}}),
    );
    drop(app);
    let mut restarted = home.open();
    let state = call(&mut restarted, json!({"op":"AppGet"}));
    assert_eq!(state.ledgers.len(), 2);
    assert_eq!(state.identity_fingerprint, empty.identity_fingerprint);
    assert_eq!(state.active_ledger.unwrap().expenses.len(), 1);
}

#[test]
fn two_installations_claim_sync_permissions_and_history() {
    let owner_home = TestHome::new();
    let guest_home = TestHome::new();
    let outsider_home = TestHome::new();
    let mut owner = owner_home.open();
    let mut guest = guest_home.open();
    let mut outsider = outsider_home.open();
    let initial = create(&mut owner, vec!["小白"]).active_ledger.unwrap();
    let id = initial.group_id;
    let owner_id = initial.active_actor_id;
    let guest_id = initial
        .participants
        .iter()
        .find(|p| p.bound_public_key.is_none())
        .unwrap()
        .participant_id
        .clone();
    ledger_call(
        &mut owner,
        &id,
        expense(&owner_id, vec![&owner_id, &guest_id], "认领前已经分摊"),
    );
    let claim = call(&mut guest, json!({"op":"AppCreateClaim","args":{"group_id":id,"participant_id":guest_id,"display_name":"小白本人"}})).transfer_code.unwrap();
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
    let mut altered: Value = serde_json::from_slice(
        &URL_SAFE_NO_PAD
            .decode(claim.strip_prefix("SBILL-CLAIM1:").unwrap())
            .unwrap(),
    )
    .unwrap();
    altered["body"]["display_name"] = json!("伪造名称");
    let tampered = format!(
        "SBILL-CLAIM1:{}",
        URL_SAFE_NO_PAD.encode(serde_json::to_vec(&altered).unwrap())
    );
    fail(
        &mut owner,
        json!({"op":"AppInspectClaim","args":{"group_id":id,"request":tampered}}),
    );
    let preview = call(
        &mut owner,
        json!({"op":"AppInspectClaim","args":{"group_id":id,"request":claim}}),
    )
    .claim_preview
    .unwrap();
    assert_eq!(
        preview["fingerprint"],
        call(&mut guest, json!({"op":"AppGet"})).identity_fingerprint
    );
    let approved = call(
        &mut owner,
        json!({"op":"AppApproveClaim","args":{"group_id":id,"participant_id":guest_id,"request":claim}}),
    );
    let welcome = approved.transfer_code.unwrap();
    let key = approved.access_key.unwrap();
    fail(
        &mut outsider,
        json!({"op":"AppJoinLedger","args":{"welcome":welcome,"access_key":key}}),
    );
    fail(
        &mut guest,
        json!({"op":"AppJoinLedger","args":{"welcome":welcome,"access_key":"wrong"}}),
    );
    let joined = call(
        &mut guest,
        json!({"op":"AppJoinLedger","args":{"welcome":welcome,"access_key":key}}),
    )
    .active_ledger
    .unwrap();
    assert_eq!(joined.active_actor_id, guest_id);
    assert_eq!(joined.expenses.len(), 1);
    assert_eq!(
        joined.expenses[0]
            .active_revision
            .as_ref()
            .unwrap()
            .resolved_shares[&guest_id],
        5000
    );
    fail(
        &mut guest,
        json!({"op":"AppAddParticipant","args":{"group_id":id,"display_name":"越权","role":"Member"}}),
    );
    fail(
        &mut guest,
        json!({"op":"AppLedgerCommand","args":{"group_id":id,"command":{"op":"SwitchActor","args":{"actor_id":owner_id}}}}),
    );
    let guest_bill = ledger_call(
        &mut guest,
        &id,
        expense(&guest_id, vec![&owner_id, &guest_id], "本人认领后记账"),
    )
    .active_ledger
    .unwrap();
    let bill = guest_bill
        .expenses
        .iter()
        .find(|e| e.active_revision.as_ref().unwrap().title == "本人认领后记账")
        .unwrap();
    assert_eq!(bill.creator_member_id, guest_id);
    ledger_call(
        &mut guest,
        &id,
        json!({"op":"AddCustomCategory","args":{"id":"cat","icon":"☕","name":"咖啡"}}),
    );
    let export = ledger_call(&mut guest, &id, json!({"op":"ExportTripDelta"}))
        .active_ledger
        .unwrap()
        .last_sync_report
        .unwrap()
        .exported_compact_code
        .unwrap();
    let synced = ledger_call(
        &mut owner,
        &id,
        json!({"op":"ImportTripDelta","args":{"payload":export}}),
    )
    .active_ledger
    .unwrap();
    assert_eq!(synced.expenses.len(), 2);
    assert_eq!(synced.custom_categories.len(), 1);
    let duplicate = ledger_call(
        &mut owner,
        &id,
        json!({"op":"ImportTripDelta","args":{"payload":export}}),
    )
    .active_ledger
    .unwrap();
    assert_eq!(duplicate.expenses.len(), 2);
    assert_eq!(duplicate.last_sync_report.unwrap().added_events, 0);
    fail(
        &mut guest,
        json!({"op":"AppLedgerCommand","args":{"group_id":id,"command":{"op":"ProposeSettlement","args":{"actor_id":guest_id,"snapshot_id":"forbidden","mode":"ByCurrencyPairwise","settlement_currency":null}}}}),
    );
    ledger_call(
        &mut guest,
        &id,
        expense(&guest_id, vec![&guest_id], "尚未同步的旧权限账目"),
    );
    ledger_call(
        &mut guest,
        &id,
        json!({"op":"AddCustomCategory","args":{"id":"stale_cat","icon":"🛑","name":"降权后的旧权限分类"}}),
    );
    let stale = ledger_call(&mut guest, &id, json!({"op":"ExportTripDelta"}))
        .active_ledger
        .unwrap()
        .last_sync_report
        .unwrap()
        .exported_compact_code
        .unwrap();
    let competing = call(&mut outsider, json!({"op":"AppCreateClaim","args":{"group_id":id,"participant_id":guest_id,"display_name":"冒领"}})).transfer_code.unwrap();
    fail(
        &mut owner,
        json!({"op":"AppApproveClaim","args":{"group_id":id,"participant_id":guest_id,"request":competing}}),
    );
    call(
        &mut owner,
        json!({"op":"AppUpdateParticipant","args":{"group_id":id,"participant_id":guest_id,"display_name":"小白","role":"Viewer","active":true}}),
    );
    let pending = ledger_call(
        &mut owner,
        &id,
        json!({"op":"ImportTripDelta","args":{"payload":stale}}),
    )
    .active_ledger
    .unwrap();
    assert_eq!(pending.expenses.len(), 2);
    assert_eq!(pending.custom_categories.len(), 1);
    assert_eq!(pending.pending_reauth_count, 2);
    let update = ledger_call(&mut owner, &id, json!({"op":"ExportTripDelta"}))
        .active_ledger
        .unwrap()
        .last_sync_report
        .unwrap()
        .exported_compact_code
        .unwrap();
    ledger_call(
        &mut guest,
        &id,
        json!({"op":"ImportTripDelta","args":{"payload":update}}),
    );
    fail(
        &mut guest,
        json!({"op":"AppLedgerCommand","args":{"group_id":id,"command":expense(&guest_id,vec![&guest_id],"只读越权")}}),
    );
    let removed = call(&mut owner, json!({"op":"AppUpdateParticipant","args":{"group_id":id,"participant_id":guest_id,"display_name":"小白","role":"Viewer","active":false}})).active_ledger.unwrap();
    assert_eq!(removed.expenses.len(), 2);
    assert!(removed
        .participants
        .iter()
        .any(|p| p.participant_id == guest_id && !p.active));
    fail(
        &mut owner,
        json!({"op":"AppLedgerCommand","args":{"group_id":id,"command":expense(&owner_id,vec![&owner_id,&guest_id],"移出后新分摊")}}),
    );
    drop(guest);
    let mut guest = guest_home.open();
    let restored = call(&mut guest, json!({"op":"AppGet"}))
        .active_ledger
        .unwrap();
    assert_eq!(restored.active_actor_id, guest_id);
    assert_eq!(restored.expenses.len(), 2);
}

#[test]
fn ffi_namespace_preserves_settlement_approval_dispatch() {
    use sbill_core::ffi::{dispatch_ffi_json, FfiResponse};
    for command in [
        json!({"op":"ResetDemoWorkspace"}),
        json!({"op":"ProposeSettlement","args":{"actor_id":"A","snapshot_id":"namespace_regression","mode":"ByCurrencyPairwise","settlement_currency":null}}),
        json!({"op":"ApproveSettlement","args":{"actor_id":"A","snapshot_id":"namespace_regression"}}),
    ] {
        let response: FfiResponse = serde_json::from_str(&dispatch_ffi_json(&command.to_string())).unwrap();
        assert!(response.ok, "{:?}", response.error);
    }
}

#[test]
fn viewer_cannot_sign_mutations_even_without_the_app_command_guard() {
    use sbill_core::{domain::{Role, SettlementMode}, error::CoreError};
    let mut session = WorkspaceSession::new_with_sample_trip().unwrap();
    session.add_participant("A", "V", "只读伙伴", Role::Viewer, true).unwrap();
    session.propose_settlement("A", "viewer_guard", SettlementMode::ByCurrencyPairwise, None).unwrap();
    let error = session.approve_settlement("V", "viewer_guard").unwrap_err();
    assert!(matches!(error, CoreError::PermissionDenied { .. }));
}

#[test]
fn legacy_upgrade_preserves_records_and_categories_without_new_demo() {
    let home = TestHome::new();
    let session = WorkspaceSession::open_or_init_persistent(home.db()).unwrap();
    session
        .repo
        .set_meta(
            "custom_categories",
            r#"[{"id":"old_cat","icon":"🎿","name":"旧分类","is_custom":true}]"#,
        )
        .unwrap();
    drop(session);
    let mut app = home.open();
    let state = call(&mut app, json!({"op":"AppGet"}));
    assert_eq!(state.ledgers.len(), 1);
    assert!(state.ledgers[0].legacy);
    let old = state.active_ledger.unwrap();
    assert_eq!(old.expenses.len(), 2);
    assert_eq!(old.custom_categories.len(), 1);
    let id = old.group_id;
    let new = create(&mut app, vec![]).active_ledger.unwrap();
    assert!(new.expenses.is_empty());
    assert!(new.custom_categories.is_empty());
    let old = call(
        &mut app,
        json!({"op":"AppSelectLedger","args":{"group_id":id}}),
    )
    .active_ledger
    .unwrap();
    assert_eq!(old.expenses.len(), 2);
    assert_eq!(old.custom_categories.len(), 1);
}

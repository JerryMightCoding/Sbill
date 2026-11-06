use sbill_core::{
    crypto::canonical_json_bytes,
    domain::{EventBody, ExpenseCategory, ExpenseDetails, PayerContribution, SignedEvent, SplitRule},
    ffi::WorkspaceSession,
    storage::LedgerRepository,
};

fn payer() -> Vec<PayerContribution> {
    vec![PayerContribution { participant_id: "A".into(), amount_minor: 100,
        original_currency: None, original_amount_minor: None, frozen_fx_rate: None }]
}
fn split() -> SplitRule { SplitRule::Equal { participants: vec!["A".into(), "B".into()] } }
fn details() -> ExpenseDetails {
    ExpenseDetails { occurred_at_ms: Some(2_051_222_400_000), category: Some(ExpenseCategory {
        id: "preset_dining".into(), icon: "🍜".into(), name: "餐厅用餐".into(), is_custom: false,
    }) }
}

#[test]
fn future_date_and_category_roundtrip_sync_and_disk_preserve_signed_history() {
    let mut session = WorkspaceSession::new_with_sample_trip().unwrap();
    let event = session.upsert_expense_with_details("A", "future", vec![], "CNY", 100,
        payer(), split(), "提前记旅行消费", "", "创建", false, Some(details())).unwrap();
    assert_eq!(event.unsigned.schema_version, 3);
    event.verify_cryptographic_integrity().unwrap();
    let raw = canonical_json_bytes(&event).unwrap();
    let decoded: SignedEvent = serde_json::from_slice(&raw).unwrap();
    assert_eq!(event, decoded);
    let home = std::env::temp_dir().join(format!("sbill_details_{}", rand::random::<u64>()));
    std::fs::create_dir(&home).unwrap();
    let path = home.join("ledger.sqlite3");
    let events = session.repo.list_events(&session.group_id).unwrap();
    {
        let mut target = LedgerRepository::open_file(&path).unwrap();
        let report = target.import_event_batch(&session.group_id, &events, Some(&session.cipher)).unwrap();
        assert_eq!(report.added_count, events.len());
        assert_eq!(target.project_group(&session.group_id).unwrap().expenses["future"].active_revision.as_ref().unwrap().details, Some(details()));
        assert_eq!(target.import_event_batch(&session.group_id, &events, Some(&session.cipher)).unwrap().added_count, 0);
    }
    let target = LedgerRepository::open_file(&path).unwrap();
    let restored = target.list_events(&session.group_id).unwrap();
    assert_eq!(restored, events);
    assert_eq!(target.project_group(&session.group_id).unwrap().expenses["future"].active_revision.as_ref().unwrap().details, Some(details()));
    drop(target);
    std::fs::remove_dir_all(home).unwrap();
}

#[test]
fn old_v1_and_v2_expense_signatures_do_not_gain_details() {
    let session = WorkspaceSession::new_with_sample_trip().unwrap();
    let event = session.repo.list_events(&session.group_id).unwrap().into_iter()
        .find(|e| matches!(e.unsigned.body, EventBody::ExpenseUpsert(_))).unwrap();
    let key = &session.member_keys[&event.unsigned.author_member_id].1;
    for version in [1, 2] {
        let mut unsigned = event.unsigned.clone();
        unsigned.schema_version = version;
        let signed = SignedEvent::sign_new(unsigned, key).unwrap();
        let raw = canonical_json_bytes(&signed).unwrap();
        let payload = match &signed.unsigned.body { EventBody::ExpenseUpsert(exp) => exp, _ => unreachable!() };
        let value = serde_json::to_value(payload).unwrap();
        assert!(value.as_object().unwrap().get("details").is_none());
        let decoded: SignedEvent = serde_json::from_slice(&raw).unwrap();
        assert_eq!(decoded, signed);
        decoded.verify_cryptographic_integrity().unwrap();
    }
}

#[test]
fn edit_void_and_conflict_merge_preserve_or_explicitly_clear_details() {
    let mut session = WorkspaceSession::new_with_sample_trip().unwrap();
    let first = session.upsert_expense_with_details("A", "edit", vec![], "CNY", 100,
        payer(), split(), "消费", "", "创建", false, Some(details())).unwrap();
    let edited = session.upsert_expense("A", "edit", vec![first.event_id.clone()], "CNY", 100,
        payer(), split(), "改标题", "", "修订", false).unwrap();
    let exp = session.repo.project_group(&session.group_id).unwrap().expenses["edit"].active_revision.clone().unwrap();
    assert_eq!(exp.details, Some(details()));
    let other = session.upsert_expense_with_details("A", "edit", vec![first.event_id], "CNY", 100,
        payer(), split(), "另一个日期", "", "并发", false, Some(ExpenseDetails { occurred_at_ms: None, category: None })).unwrap();
    let parents = vec![edited.event_id, other.event_id];
    let count = session.repo.total_event_count().unwrap();
    assert!(session.upsert_expense("A", "edit", parents.clone(), "CNY", 100,
        payer(), split(), "合并", "", "合并", false).is_err());
    assert_eq!(session.repo.total_event_count().unwrap(), count);
    let merged = session.upsert_expense_with_details("A", "edit", parents, "CNY", 100,
        payer(), split(), "合并", "", "合并", false, Some(details())).unwrap();
    session.upsert_expense("A", "edit", vec![merged.event_id], "CNY", 0,
        vec![], split(), "作废", "", "作废", true).unwrap();
    let exp = session.repo.project_group(&session.group_id).unwrap().expenses["edit"].active_revision.clone().unwrap();
    assert!(exp.voided);
    assert_eq!(exp.details, Some(details()));
}

#[test]
fn invalid_calendar_and_category_are_rejected_without_writes() {
    let mut session = WorkspaceSession::new_with_sample_trip().unwrap();
    let count = session.repo.total_event_count().unwrap();
    for invalid in [
        ExpenseDetails { occurred_at_ms: Some(i64::MAX), category: None },
        ExpenseDetails { occurred_at_ms: None, category: Some(ExpenseCategory {
            id: "".into(), name: "类别".into(), icon: "".into(), is_custom: true,
        }) },
    ] {
        assert!(session.upsert_expense_with_details("A", "bad", vec![], "CNY", 100,
            payer(), split(), "非法资料", "", "创建", false, Some(invalid)).is_err());
        assert_eq!(session.repo.total_event_count().unwrap(), count);
    }
}

use sbill_core::{crypto::canonical_json_bytes, domain::*, ffi::WorkspaceSession,
    storage::{build_projection, LedgerRepository}};

#[test]
fn valid_event_and_bad_financial_event_are_rejected_as_one_batch() {
    let mut source = WorkspaceSession::new_with_sample_trip().unwrap();
    let initial = source.repo.list_events(&source.group_id).unwrap();
    let mut receiver = LedgerRepository::open_in_memory().unwrap();
    receiver.import_event_batch(&source.group_id, &initial, None).unwrap();
    let category = source.upsert_custom_category("A", "atomic_category", "🎿", "不能部分入账", false).unwrap();
    let mut malformed = initial.iter().find(|e| matches!(&e.unsigned.body, EventBody::ExpenseUpsert(x) if x.currency == "CNY")).unwrap().unsigned.clone();
    malformed.sequence = category.unsigned.sequence + 1;
    malformed.previous_event_id = Some(category.event_id.clone());
    if let EventBody::ExpenseUpsert(payload) = &mut malformed.body {
        payload.expense_id = "invalid_amount".into();
        payload.total_minor += 1;
    }
    let bad = SignedEvent::sign_new(malformed, &source.member_keys["A"].1).unwrap();
    let before = receiver.total_event_count().unwrap();
    let result = receiver.import_event_batch(&source.group_id, &[category, bad], None).unwrap();
    assert_eq!(result.added_count, 0);
    assert_eq!(result.rejected_events.len(), 2);
    assert_eq!(receiver.total_event_count().unwrap(), before);
    assert!(receiver.project_group(&source.group_id).unwrap().custom_categories.is_empty());
}

#[test]
fn low_sequence_deletion_removes_observed_high_sequence_add_not_concurrent_add() {
    let mut source = WorkspaceSession::new_with_sample_trip().unwrap();
    for index in 0..15 {
        source.upsert_custom_category("A", &format!("padding_{index}"), "🏷️", &format!("其他{index}"), false).unwrap();
    }
    let add = source.upsert_custom_category("A", "ski_a", "🎿", "滑雪", false).unwrap();
    let delete = source.upsert_custom_category("B", "ski_a", "🎿", "滑雪", true).unwrap();
    assert!(delete.unsigned.sequence < add.unsigned.sequence);
    let mut events = source.repo.list_events(&source.group_id).unwrap();
    assert!(!build_projection(&source.group_id, &events).unwrap().custom_categories.iter().any(|c| c.name == "滑雪"));
    let mut concurrent = add.unsigned.clone();
    concurrent.device_id = "dev_c_concurrent_category".into();
    concurrent.author_member_id = "C".into();
    concurrent.author_public_key = source.member_keys["C"].1.public_key_b64();
    concurrent.sequence = 1;
    concurrent.previous_event_id = None;
    if let EventBody::CategoryUpsert(payload) = &mut concurrent.body { payload.category_id = "ski_concurrent".into(); }
    events.push(SignedEvent::sign_new(concurrent, &source.member_keys["C"].1).unwrap());
    let expected = build_projection(&source.group_id, &events).unwrap().custom_categories;
    assert!(expected.iter().any(|c| c.name == "滑雪" && c.id == "ski_concurrent"));
    events.reverse();
    assert_eq!(build_projection(&source.group_id, &events).unwrap().custom_categories, expected);
    events.retain(|event| event.event_id != add.event_id);
    let missing = build_projection(&source.group_id, &events).unwrap();
    assert!(missing.pending_dependency_events.contains(&delete.event_id));
}

#[test]
fn old_v1_signatures_remain_valid_and_future_schema_is_rejected() {
    let source = WorkspaceSession::new_with_sample_trip().unwrap();
    let mut unsigned = source.repo.list_events(&source.group_id).unwrap()[0].unsigned.clone();
    unsigned.schema_version = 1;
    let old = SignedEvent::sign_new(unsigned.clone(), &source.member_keys["A"].1).unwrap();
    let decoded: SignedEvent = serde_json::from_slice(&canonical_json_bytes(&old).unwrap()).unwrap();
    decoded.verify_cryptographic_integrity().unwrap();
    unsigned.schema_version = CURRENT_SCHEMA_VERSION + 1;
    let future = SignedEvent::sign_new(unsigned, &source.member_keys["A"].1).unwrap();
    assert!(future.verify_cryptographic_integrity().is_err());
}

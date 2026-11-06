use sbill_core::{domain::*, ffi::WorkspaceSession, storage::build_projection};

#[test]
fn huge_sequence_and_reused_device_identity_are_rejected() {
    let source = WorkspaceSession::new_with_sample_trip().unwrap();
    let base = source.repo.list_events(&source.group_id).unwrap();
    let mut huge = base[0].unsigned.clone();
    huge.sequence = 50_000;
    huge.previous_event_id = None;
    let mut events = base.clone();
    events.push(SignedEvent::sign_new(huge.clone(), &source.member_keys["A"].1).unwrap());
    assert!(build_projection(&source.group_id, &events).is_err());
    huge.sequence = u64::MAX;
    assert!(SignedEvent::sign_new(huge, &source.member_keys["A"].1).unwrap().verify_cryptographic_integrity().is_err());
    let mut reused = base[0].unsigned.clone();
    reused.sequence = 3;
    reused.author_member_id = "B".into();
    reused.author_public_key = source.member_keys["B"].1.public_key_b64();
    events = base;
    events.push(SignedEvent::sign_new(reused, &source.member_keys["B"].1).unwrap());
    assert!(build_projection(&source.group_id, &events).is_err());
}

#[test]
fn v1_category_roundtrip_retains_signature_without_new_fields() {
    let source = WorkspaceSession::new_with_sample_trip().unwrap();
    let mut old = source.repo.list_events(&source.group_id).unwrap()[0].unsigned.clone();
    old.schema_version = 1;
    old.body = EventBody::CategoryUpsert(CustomCategoryUpsertPayload {
        category_id: "old_category".into(), icon: "🎿".into(), name: "旧分类".into(),
        deleted: false, observed_add_event_ids: Vec::new(),
    });
    let signed = SignedEvent::sign_new(old, &source.member_keys["A"].1).unwrap();
    let json = serde_json::to_string(&signed).unwrap();
    assert!(!json.contains("observed_add_event_ids"));
    serde_json::from_str::<SignedEvent>(&json).unwrap().verify_cryptographic_integrity().unwrap();
}

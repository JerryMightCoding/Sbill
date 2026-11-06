use sbill_core::{domain::SettlementMode, ffi::WorkspaceSession};

#[test]
fn stale_and_duplicate_local_commit_never_poison_commit_chain() {
    let mut session = WorkspaceSession::new_with_sample_trip().unwrap();
    for id in ["chosen", "stale"] {
        session.propose_settlement("A", id, SettlementMode::ByCurrencyPairwise, None).unwrap();
        for member in ["A", "B", "C", "D"] { session.approve_settlement(member, id).unwrap(); }
    }
    session.commit_settlement("A", "chosen").unwrap();
    let count = session.repo.total_event_count().unwrap();
    assert!(session.commit_settlement("A", "chosen").is_err());
    assert!(session.commit_settlement("A", "stale").is_err());
    assert!(session.approve_settlement("A", "stale").is_err());
    assert_eq!(session.repo.total_event_count().unwrap(), count);
    assert!(session.repo.project_group(&session.group_id).unwrap().commit_conflicts.is_empty());
}

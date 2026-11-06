use std::collections::BTreeMap;
use sbill_core::{domain::SignedEvent, ffi::WorkspaceSession, storage::LedgerRepository,
    workspace::{AppWorkspace, AppCommand}};

#[test]
fn actual_v1_database_opens_without_reseeding_or_changing_signed_history() {
    let source = WorkspaceSession::new_with_sample_trip().unwrap();
    let original = source.repo.list_events(&source.group_id).unwrap();
    let mut remapped = BTreeMap::new();
    let mut legacy = Vec::new();
    for event in original {
        let mut unsigned = event.unsigned;
        unsigned.schema_version = 1;
        unsigned.previous_event_id = unsigned.previous_event_id.map(|id| remapped.get(&id).cloned().unwrap_or(id));
        unsigned.policy_version_id = remapped.get(&unsigned.policy_version_id).cloned().unwrap_or(unsigned.policy_version_id);
        let key = &source.member_keys[&unsigned.author_member_id].1;
        let signed = SignedEvent::sign_new(unsigned, key).unwrap();
        remapped.insert(event.event_id, signed.event_id.clone());
        legacy.push(signed);
    }
    let root = std::env::temp_dir().join(format!("sbill_v1_upgrade_{}", hex::encode(rand::random::<[u8;16]>() )));
    std::fs::create_dir(&root).unwrap();
    let path = root.join("ledger.sqlite3");
    {
        let mut repo = LedgerRepository::open_file(&path).unwrap();
        repo.import_event_batch(&source.group_id, &legacy, Some(&source.cipher)).unwrap();
        repo.set_meta("group_id", &source.group_id).unwrap();
        repo.set_meta("active_actor_id", "A").unwrap();
        repo.set_meta("cipher_b64", &source.cipher.to_b64()).unwrap();
        let (device, key) = &source.member_keys["A"];
        repo.save_member_key("A", device, &key.secret_bytes()).unwrap();
    }
    {
        let mut app = AppWorkspace::open(&path).unwrap();
        let state = app.execute(AppCommand::AppGet).unwrap();
        assert_eq!(state.ledgers.len(), 1);
        assert!(state.ledgers[0].legacy);
        let active = state.active_ledger.unwrap();
        assert_eq!(active.expenses.len(), 2);
        assert_eq!(active.total_event_count, legacy.len());
    }
    {
        let repo = LedgerRepository::open_file(&path).unwrap();
        assert_eq!(repo.list_events(&source.group_id).unwrap(), legacy);
    }
    std::fs::remove_dir_all(&root).unwrap();
}

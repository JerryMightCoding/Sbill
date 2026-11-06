use sbill_core::{domain::{FxRateSpec, Role, SettlementMode, PayerContribution, SplitRule},
    ffi::WorkspaceSession, error::CoreError};

#[test]
fn viewer_can_only_sign_own_financial_consent() {
    let mut session = WorkspaceSession::new_with_sample_trip().unwrap();
    session.add_participant("A", "V", "只读伙伴", Role::Viewer, true).unwrap();
    session.upsert_expense("A", "viewer_debt", vec![], "CNY", 100,
        vec![PayerContribution { participant_id:"A".into(), amount_minor:100,
            original_currency:None, original_amount_minor:None, frozen_fx_rate:None }],
        SplitRule::Equal {participants:vec!["V".into()]}, "只读伙伴的消费", "", "创建", false).unwrap();
    session.propose_settlement("A", "viewer_consent", SettlementMode::ByCurrencyPairwise, None).unwrap();
    session.approve_settlement("V", "viewer_consent").unwrap();
    assert!(matches!(session.propose_settlement("V", "unauthorized", SettlementMode::ByCurrencyPairwise, None),
        Err(CoreError::PermissionDenied { .. })));
    assert!(matches!(session.declare_repayment("V", "forged", "A", "V", "CNY", 1, None, ""),
        Err(CoreError::PermissionDenied { .. })));
    let decl = session.declare_repayment("V", "own", "V", "A", "CNY", 1, None, "").unwrap();
    assert!(matches!(session.confirm_repayment("V", "own", &decl.event_id, None),
        Err(CoreError::PermissionDenied { .. })));
    session.confirm_repayment("A", "own", &decl.event_id, None).unwrap();
    let other = session.declare_repayment("A", "receipt", "A", "V", "CNY", 1, None, "").unwrap();
    session.confirm_repayment("V", "receipt", &other.event_id, None).unwrap();
}

#[test]
fn pending_receipt_blocks_proposal_approval_and_commit() {
    let mut session = WorkspaceSession::new_with_sample_trip().unwrap();
    session.propose_settlement("A", "before_payment", SettlementMode::ByCurrencyPairwise, None).unwrap();
    for actor in ["A", "B", "C", "D"] { session.approve_settlement(actor, "before_payment").unwrap(); }
    let decl = session.declare_repayment("A", "pending", "A", "B", "CNY", 100, None, "").unwrap();
    assert!(session.propose_settlement("A", "blocked", SettlementMode::ByCurrencyPairwise, None).is_err());
    assert!(session.commit_settlement("A", "before_payment").is_err());
    assert!(session.confirm_repayment("B", "pending", "wrong_declaration", None).is_err());
    session.confirm_repayment("B", "pending", &decl.event_id, None).unwrap();
    session.propose_settlement("A", "after_payment", SettlementMode::ByCurrencyPairwise, None).unwrap();
}

#[test]
fn malformed_fx_never_panics_or_accepts_partial_metadata() {
    let rate = FxRateSpec {base_currency:"JPY".into(), quote_currency:"CNY".into(), numerator:1, denominator:0};
    assert!(rate.convert_minor(1, 0, 2).is_err());
    let mut session = WorkspaceSession::new_with_sample_trip().unwrap();
    let before = session.repo.total_event_count().unwrap();
    let result = session.upsert_expense("A", "invalid_fx", vec![], "CNY", 100,
        vec![PayerContribution {participant_id:"A".into(), amount_minor:100,
            original_currency:Some("JPY".into()), original_amount_minor:None, frozen_fx_rate:None}],
        SplitRule::Equal {participants:vec!["A".into()]}, "无效外币", "", "创建", false);
    assert!(result.is_err());
    assert_eq!(session.repo.total_event_count().unwrap(), before);
}

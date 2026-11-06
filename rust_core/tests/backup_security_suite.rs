use sbill_core::{crypto::DeviceKeypair, sync::MemberIdentityBackup};

#[test]
fn backup_uses_random_salt_argon2id_and_authenticates_identity() {
    let key = DeviceKeypair::generate();
    let phrase = "correct_horse_battery";
    let first = MemberIdentityBackup::create("member", "device", &key, phrase).unwrap();
    let second = MemberIdentityBackup::create("member", "device", &key, phrase).unwrap();
    assert_eq!(first.format_version, 2);
    assert_eq!(first.kdf, "argon2id-v19-m65536-t3-p1");
    assert_ne!(first.salt_b64, second.salt_b64);
    assert_ne!(first.encrypted_secret_b64, second.encrypted_secret_b64);
    assert_eq!(first.restore(phrase).unwrap().public_key_b64(), key.public_key_b64());
    let mut tampered = first;
    tampered.device_id = "different_device".into();
    assert!(tampered.restore(phrase).is_err());
}

#[test]
fn weak_password_and_unbounded_kdf_or_legacy_parameters_are_rejected() {
    let key = DeviceKeypair::generate();
    assert!(MemberIdentityBackup::create("member", "device", &key, "123456").is_err());
    let mut backup = MemberIdentityBackup::create("member", "device", &key, "correct_horse_battery").unwrap();
    backup.kdf = "argon2id-v19-m4294967295-t999-p999".into();
    assert!(backup.restore("correct_horse_battery").is_err());
    let mut raw = serde_json::to_value(backup).unwrap();
    raw.as_object_mut().unwrap().remove("format_version");
    raw.as_object_mut().unwrap().remove("kdf");
    let legacy: MemberIdentityBackup = serde_json::from_value(raw).unwrap();
    assert_eq!(legacy.format_version, 1);
    assert!(legacy.restore("correct_horse_battery").is_err());
}

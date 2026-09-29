#![allow(clippy::unwrap_used)]

use std::fs;
use supplier_hub::{
    exchange::{self, ExchangeConfig, ExchangeRole},
    model::{Publication, PublicationDraft},
    store::Store,
};
use uuid::Uuid;

const KEY: &[u8] = b"test-only-exchange-key-32-bytes-long";
fn draft() -> PublicationDraft {
    serde_json::from_str(include_str!("../examples/supplier.json")).unwrap()
}
fn config(path: &std::path::Path, role: ExchangeRole, origin: Uuid) -> ExchangeConfig {
    ExchangeConfig {
        role,
        directory: path.into(),
        trusted_origin: Some(origin),
        interval_seconds: 1,
        resend_seconds: 60,
        max_files_per_tick: 50,
    }
}

#[test]
fn authenticated_envelope_rejects_tampering_wrong_key_origin_and_protocol() {
    let publication = Publication {
        origin: Uuid::new_v4(),
        draft: draft(),
    };
    let bytes = exchange::encode_package(&publication, KEY).unwrap();
    assert_eq!(
        exchange::decode_package(&bytes, publication.origin, KEY)
            .unwrap()
            .2,
        publication
    );
    assert!(exchange::decode_package(&bytes, Uuid::new_v4(), KEY).is_err());
    assert!(
        exchange::decode_package(
            &bytes,
            publication.origin,
            b"different-test-key-32-bytes-long!!"
        )
        .is_err()
    );
    let mut value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    value["payload"] = serde_json::json!(
        value["payload"]
            .as_str()
            .unwrap()
            .replace("示例设备供应商", "伪造供应商")
    );
    assert!(
        exchange::decode_package(
            &serde_json::to_vec(&value).unwrap(),
            publication.origin,
            KEY
        )
        .is_err()
    );
    value = serde_json::from_slice(&bytes).unwrap();
    value["protocol"] = serde_json::json!(2);
    assert!(
        exchange::decode_package(
            &serde_json::to_vec(&value).unwrap(),
            publication.origin,
            KEY
        )
        .is_err()
    );
    assert!(
        exchange::decode_package(
            &vec![b' '; exchange::MAX_PACKAGE_BYTES as usize + 1],
            publication.origin,
            KEY
        )
        .is_err()
    );
}

#[test]
fn export_progress_and_imported_receipts_survive_reopen_without_overwriting_local_data() {
    let tmp = tempfile::tempdir().unwrap();
    let a = Uuid::new_v4();
    let b = Uuid::new_v4();
    let out = tmp.path().join("out");
    let inbox = tmp.path().join("in");
    fs::create_dir(&inbox).unwrap();
    let source_path = tmp.path().join("source.db");
    let target_path = tmp.path().join("target.db");
    let mut source = Store::open(&source_path).unwrap();
    let mut target = Store::open(&target_path).unwrap();
    source.publish(a, draft()).unwrap();
    target.publish(b, draft()).unwrap();
    let export = config(&out, ExchangeRole::Export, a);
    let import = config(&inbox, ExchangeRole::Import, a);
    assert_eq!(
        exchange::run_once(&mut source, a, &export, KEY)
            .unwrap()
            .exported,
        1
    );
    for file in fs::read_dir(&out).unwrap() {
        let file = file.unwrap();
        fs::copy(file.path(), inbox.join(file.file_name())).unwrap();
    }
    assert_eq!(
        exchange::run_once(&mut target, b, &import, KEY)
            .unwrap()
            .imported,
        1
    );
    drop(source);
    drop(target);
    let mut source = Store::open(&source_path).unwrap();
    let mut target = Store::open(&target_path).unwrap();
    assert_eq!(
        exchange::run_once(&mut source, a, &export, KEY)
            .unwrap()
            .exported,
        0
    );
    assert_eq!(
        exchange::run_once(&mut target, b, &import, KEY)
            .unwrap()
            .duplicates,
        1
    );
    assert_eq!(target.status().unwrap().publication_count, 2);
    source
        .mark_exported(a, draft().publication_id, 1, 0)
        .unwrap();
    assert_eq!(
        exchange::run_once(&mut source, a, &export, KEY)
            .unwrap()
            .exported,
        1
    );
    assert_eq!(fs::read_dir(&out).unwrap().count(), 2);
    for file in fs::read_dir(&out).unwrap() {
        let file = file.unwrap();
        fs::copy(file.path(), inbox.join(file.file_name())).unwrap();
    }
    assert_eq!(
        exchange::run_once(&mut target, b, &import, KEY)
            .unwrap()
            .duplicates,
        2
    );
    assert_eq!(target.status().unwrap().revision_count, 2);
}

#[test]
fn partial_and_poison_files_do_not_starve_following_files_and_old_versions_do_not_replace_new() {
    let tmp = tempfile::tempdir().unwrap();
    let origin = Uuid::new_v4();
    let b = Uuid::new_v4();
    let mut receiver = Store::open(tmp.path().join("hub.db")).unwrap();
    let old = Publication {
        origin,
        draft: draft(),
    };
    let mut newer = old.clone();
    newer.draft.revision = 2;
    newer.draft.records[0]
        .data
        .insert("name".into(), serde_json::json!("较新供应商"));
    let bytes = exchange::encode_package(&old, KEY).unwrap();
    fs::write(tmp.path().join("a.hubpkg"), b"broken").unwrap();
    fs::write(tmp.path().join("b.hubpkg"), &bytes[..bytes.len() / 2]).unwrap();
    fs::write(
        tmp.path().join("c.hubpkg"),
        exchange::encode_package(&newer, KEY).unwrap(),
    )
    .unwrap();
    let mut conf = config(tmp.path(), ExchangeRole::Import, origin);
    conf.max_files_per_tick = 1;
    assert_eq!(
        exchange::run_once(&mut receiver, b, &conf, KEY)
            .unwrap()
            .failed,
        1
    );
    assert_eq!(
        exchange::run_once(&mut receiver, b, &conf, KEY)
            .unwrap()
            .failed,
        1
    );
    assert_eq!(receiver.status().unwrap().revision_count, 0);
    assert_eq!(
        exchange::run_once(&mut receiver, b, &conf, KEY)
            .unwrap()
            .imported,
        1
    );
    fs::write(tmp.path().join("b.hubpkg"), bytes).unwrap();
    assert_eq!(
        exchange::run_once(&mut receiver, b, &conf, KEY)
            .unwrap()
            .failed,
        1
    );
    assert_eq!(
        exchange::run_once(&mut receiver, b, &conf, KEY)
            .unwrap()
            .imported,
        1
    );
    assert_eq!(
        receiver
            .get(origin, old.draft.publication_id, None)
            .unwrap()
            .draft
            .revision,
        2
    );
    assert_eq!(receiver.status().unwrap().revision_count, 2);
}

#[test]
fn failed_export_does_not_advance_progress_and_backlog_is_exported_when_enabled() {
    let tmp = tempfile::tempdir().unwrap();
    let origin = Uuid::new_v4();
    let mut store = Store::open(":memory:").unwrap();
    store.publish(origin, draft()).unwrap();
    let path = tmp.path().join("not_a_directory");
    fs::write(&path, b"occupied").unwrap();
    assert!(
        exchange::run_once(
            &mut store,
            origin,
            &config(&path, ExchangeRole::Export, origin),
            KEY
        )
        .is_err()
    );
    assert_eq!(store.status().unwrap().exported_versions, 0);
    assert_eq!(
        exchange::run_once(
            &mut store,
            origin,
            &config(&tmp.path().join("out"), ExchangeRole::Export, origin),
            KEY
        )
        .unwrap()
        .exported,
        1
    );
}

#[cfg(unix)]
#[test]
fn inbox_symlinks_are_ignored() {
    let tmp = tempfile::tempdir().unwrap();
    let origin = Uuid::new_v4();
    let source = tmp.path().join("outside.json");
    fs::write(
        &source,
        exchange::encode_package(
            &Publication {
                origin,
                draft: draft(),
            },
            KEY,
        )
        .unwrap(),
    )
    .unwrap();
    std::os::unix::fs::symlink(source, tmp.path().join("linked.hubpkg")).unwrap();
    let mut store = Store::open(":memory:").unwrap();
    assert_eq!(
        exchange::run_once(
            &mut store,
            Uuid::new_v4(),
            &config(tmp.path(), ExchangeRole::Import, origin),
            KEY
        )
        .unwrap()
        .scanned,
        0
    );
}

#[test]
fn multibyte_failure_reports_remain_within_persistent_byte_budget() {
    let tmp = tempfile::tempdir().unwrap();
    let origin = Uuid::new_v4();
    for n in 0..15 {
        let name = format!("{}-{n}.hubpkg", "错".repeat(75));
        let malformed = format!("{{\"{}\":0}}", "错".repeat(240));
        fs::write(tmp.path().join(name), malformed).unwrap();
    }
    let mut store = Store::open(":memory:").unwrap();
    let report = exchange::run_once(
        &mut store,
        Uuid::new_v4(),
        &config(tmp.path(), ExchangeRole::Import, origin),
        KEY,
    )
    .unwrap();
    assert_eq!(report.failed, 15);
    assert!(serde_json::to_vec(&report).unwrap().len() <= 4000);
    assert_eq!(store.status().unwrap().revision_count, 0);
}

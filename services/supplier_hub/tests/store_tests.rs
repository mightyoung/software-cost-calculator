#![allow(clippy::unwrap_used)]
use serde_json::json;
use supplier_hub::{
    model::{Publication, PublicationDraft, RecordKey, RecordSnapshot},
    store::{SearchQuery, Store},
};
use uuid::Uuid;

fn supplier() -> PublicationDraft {
    let id = Uuid::new_v4();
    PublicationDraft {
        publication_id: Uuid::new_v4(),
        revision: 1,
        withdrawn: false,
        root: RecordKey {
            entity_type: "supplier".into(),
            entity_id: id,
        },
        records: vec![RecordSnapshot {
            entity_type: "supplier".into(),
            entity_id: id,
            source_version: 1,
            data: serde_json::from_value(
                json!({"name":"Reliable 100%_Supplier","rating":"preferred"}),
            )
            .unwrap(),
        }],
    }
}

#[test]
fn publication_origin_overhead_cannot_commit_an_unexportable_backlog_item() {
    const LIMIT: usize = 1024 * 1024;
    let origin = Uuid::new_v4();
    let mut draft = supplier();
    let supplier_id = draft.root.entity_id;
    // Build a valid supplier closure close to the wire limit using bounded
    // contact strings. Reserve room for one final adjustable contact.
    while serde_json::to_vec(&draft).unwrap().len() < LIMIT - 10_000 {
        draft.records.push(RecordSnapshot {
            entity_type: "contact".into(),
            entity_id: Uuid::new_v4(),
            source_version: 1,
            data: serde_json::from_value(json!({
                "supplier_id": supplier_id,
                "name": "x".repeat(2000),
                "phone": "1",
                "notes": "x".repeat(2000)
            }))
            .unwrap(),
        });
    }
    // Adjust multiple fields instead of exceeding a single string's bound.
    while serde_json::to_vec(&draft).unwrap().len() < LIMIT - 6_000 {
        draft.records.push(RecordSnapshot {
            entity_type: "contact".into(),
            entity_id: Uuid::new_v4(),
            source_version: 1,
            data: serde_json::from_value(json!({
                "supplier_id": supplier_id,"name":"x","phone":"1","notes":"x"
            }))
            .unwrap(),
        });
        let size = serde_json::to_vec(&draft).unwrap().len();
        let mut remaining = (LIMIT - 6_000).saturating_sub(size);
        let record = draft.records.last_mut().unwrap();
        for key in ["name", "notes", "phone"] {
            let add = remaining.min(1999);
            record.data.insert(key.into(), json!("x".repeat(add + 1)));
            remaining -= add;
        }
    }
    draft.records.push(RecordSnapshot {
        entity_type: "contact".into(),
        entity_id: Uuid::new_v4(),
        source_version: 1,
        data: serde_json::from_value(
            json!({"supplier_id":supplier_id,"name":"x","phone":"1","notes":"x"}),
        )
        .unwrap(),
    });
    let mut remaining = LIMIT - 8 - serde_json::to_vec(&draft).unwrap().len();
    let record = draft.records.last_mut().unwrap();
    for key in ["name", "notes", "phone"] {
        let add = remaining.min(1999);
        record.data.insert(key.into(), json!("x".repeat(add + 1)));
        remaining -= add;
    }
    assert_eq!(remaining, 0);
    assert_eq!(serde_json::to_vec(&draft).unwrap().len(), LIMIT - 8);
    draft.validate().unwrap();
    let publication = Publication {
        origin,
        draft: draft.clone(),
    };
    assert!(serde_json::to_vec(&publication).unwrap().len() > LIMIT);
    assert!(publication.validate().is_err());
    let mut store = Store::open(":memory:").unwrap();
    assert!(store.publish(origin, draft).is_err());
    assert_eq!(store.status().unwrap().revision_count, 0);
    let valid = supplier();
    store.publish(origin, valid.clone()).unwrap();
    let pending = store.pending_exports(origin, 0, 60, 10).unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].draft.publication_id, valid.publication_id);
}
#[test]
fn immutable_retry_reopen_withdrawal_and_backup() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("hub.db");
    let origin = Uuid::new_v4();
    let mut draft = supplier();
    let mut store = Store::open(&path).unwrap();
    assert!(!store.publish(origin, draft.clone()).unwrap().duplicate);
    assert!(store.publish(origin, draft.clone()).unwrap().duplicate);
    let mut changed = draft.clone();
    changed.records[0]
        .data
        .insert("name".into(), json!("Changed"));
    assert!(store.publish(origin, changed).is_err());
    draft.revision = 3;
    assert!(store.publish(origin, draft.clone()).is_err());
    draft.revision = 2;
    draft.withdrawn = true;
    store.publish(origin, draft.clone()).unwrap();
    assert!(store.search(&SearchQuery::default()).unwrap().is_empty());
    assert_eq!(
        store
            .history(origin, draft.publication_id, 20, 0)
            .unwrap()
            .len(),
        2
    );
    drop(store);
    let store = Store::open(&path).unwrap();
    assert_eq!(
        store
            .get(origin, draft.publication_id, None)
            .unwrap()
            .draft
            .revision,
        2
    );
    let backup = dir.path().join("backup.db");
    store.backup(&backup).unwrap();
    assert!(store.backup(&backup).is_err());
    let copy = Store::open(backup).unwrap();
    assert_eq!(copy.status().unwrap().revision_count, 2);
}
#[test]
fn imports_out_of_order_and_ledger_rolls_back_on_conflict() {
    let mut store = Store::open(":memory:").unwrap();
    let origin = Uuid::new_v4();
    let mut p = Publication {
        origin,
        draft: supplier(),
    };
    p.draft.revision = 3;
    let digest = "a".repeat(64);
    store.import_package("p3", &digest, &p).unwrap();
    p.draft.revision = 1;
    store.import_package("p1", &digest, &p).unwrap();
    assert_eq!(
        store
            .get(origin, p.draft.publication_id, None)
            .unwrap()
            .draft
            .revision,
        3
    );
    assert!(store.import_package("p1", &digest, &p).unwrap().duplicate);
    p.draft.records[0]
        .data
        .insert("name".into(), json!("Tampered"));
    assert!(store.import_package("p1-conflict", &digest, &p).is_err());
    assert_eq!(store.status().unwrap().received_packages, 2);
    assert!(store.import_package("p1", &"b".repeat(64), &p).is_err());
}
#[test]
fn search_treats_wildcards_as_literal_and_export_retries_survive_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("hub.db");
    let origin = Uuid::new_v4();
    let draft = supplier();
    let mut store = Store::open(&path).unwrap();
    store.publish(origin, draft.clone()).unwrap();
    assert_eq!(
        store
            .search(&SearchQuery {
                q: "100%_".into(),
                ..Default::default()
            })
            .unwrap()
            .len(),
        1
    );
    assert!(
        store
            .search(&SearchQuery {
                q: "missing%".into(),
                ..Default::default()
            })
            .unwrap()
            .is_empty()
    );
    store
        .mark_exported(origin, draft.publication_id, 1, 100)
        .unwrap();
    drop(store);
    let store = Store::open(path).unwrap();
    assert!(
        store
            .pending_exports(origin, 150, 100, 10)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        store.pending_exports(origin, 201, 100, 10).unwrap().len(),
        1
    );
    assert!(
        store
            .pending_exports(Uuid::new_v4(), 201, 100, 10)
            .unwrap()
            .is_empty()
    );
}
#[test]
fn closure_decimals_unknown_fields_and_roundtrip() {
    let mut draft = supplier();
    let supplier_id = draft.root.entity_id;
    let product_id = Uuid::new_v4();
    let quotation_id = Uuid::new_v4();
    draft.root = RecordKey {
        entity_type: "quotation".into(),
        entity_id: quotation_id,
    };
    draft.records.push(RecordSnapshot {
        entity_type: "product".into(),
        entity_id: product_id,
        source_version: 1,
        data: serde_json::from_value(json!({"name":"Pump","unit":"set"})).unwrap(),
    });
    draft.records.push(RecordSnapshot{entity_type:"quotation".into(),entity_id:quotation_id,source_version:1,data:serde_json::from_value(json!({"supplier_id":supplier_id,"product_id":product_id,"price":"123456789012.123456","min_qty":"1","currency":"CNY","tax_mode":"included","unit_snapshot":"set","capture_mode":"historical"})).unwrap()});
    draft.validate().unwrap();
    let p = Publication {
        origin: Uuid::new_v4(),
        draft: draft.clone(),
    };
    let encoded = serde_json::to_vec(&p).unwrap();
    let decoded: Publication = serde_json::from_slice(&encoded).unwrap();
    assert_eq!(decoded, p);
    let mut reordered = p.clone();
    reordered.draft.records.reverse();
    assert_eq!(p.digest().unwrap(), reordered.digest().unwrap());
    let mut unknown = serde_json::to_value(&p).unwrap();
    unknown["unexpected"] = json!(true);
    assert!(serde_json::from_value::<Publication>(unknown).is_err());
    draft.records[2].data.insert("price".into(), json!(1.25));
    assert!(draft.validate().is_err());
    draft.records[2].data.insert("price".into(), json!("1"));
    draft.records[2]
        .data
        .insert("attachment_ids".into(), json!([Uuid::new_v4()]));
    assert!(draft.validate().is_err());
    draft.records[2].data.remove("attachment_ids");
    draft.records.remove(1);
    assert!(draft.validate().is_err());
}
#[test]
fn rejects_extra_records_and_future_schema() {
    let mut draft = supplier();
    draft.records.extend(supplier().records);
    assert!(draft.validate().is_err());
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("future.db");
    let conn = rusqlite::Connection::open(&path).unwrap();
    conn.pragma_update(None, "user_version", 99).unwrap();
    drop(conn);
    assert!(Store::open(path).is_err());
}

#[test]
fn foreign_database_is_rejected_without_any_persistent_write() {
    let dir = tempfile::tempdir().unwrap();
    for (name, version, application_id) in [
        ("client", 0, 0),
        ("foreign-v1", 1, 0),
        ("foreign-magic", 1, 12345),
        ("future", 99, 0x5348_5542),
    ] {
        let path = dir.path().join(format!("{name}.db"));
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.execute_batch("CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL); INSERT INTO meta VALUES('schema_version','10');").unwrap();
        conn.pragma_update(None, "user_version", version).unwrap();
        conn.pragma_update(None, "application_id", application_id)
            .unwrap();
        drop(conn);
        let before = std::fs::read(&path).unwrap();
        assert!(Store::open(&path).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), before, "changed {name}");
        assert!(!path.with_extension("db-wal").exists());
        let conn = rusqlite::Connection::open(&path).unwrap();
        assert_eq!(
            conn.query_row(
                "SELECT value FROM meta WHERE key='schema_version'",
                [],
                |r| r.get::<_, String>(0)
            )
            .unwrap(),
            "10"
        );
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='publications'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            0
        );
    }
    let fresh = dir.path().join("hub.db");
    drop(Store::open(&fresh).unwrap());
    let conn = rusqlite::Connection::open(&fresh).unwrap();
    assert_eq!(
        conn.pragma_query_value(None, "application_id", |r| r.get::<_, i32>(0))
            .unwrap(),
        0x5348_5542
    );
    conn.pragma_update(None, "application_id", 0).unwrap();
    drop(conn);
    assert!(Store::open(fresh).is_err());
}

#[test]
fn quote_project_and_inquiry_closure_preserves_context() {
    let mut draft = supplier();
    let supplier_id = draft.root.entity_id;
    let product_id = Uuid::new_v4();
    let quote_id = Uuid::new_v4();
    let project_id = Uuid::new_v4();
    let inquiry_id = Uuid::new_v4();
    draft.root = RecordKey {
        entity_type: "quotation".into(),
        entity_id: quote_id,
    };
    for (kind, id, data) in [
        (
            "product",
            product_id,
            json!({"name":"Valve","unit":"台","specification":"DN50 PN16"}),
        ),
        (
            "project",
            project_id,
            json!({"name":"Factory retrofit","code":"P-001","currency":"CNY","tax_mode":"included","markup_rate":"10","status":"active"}),
        ),
        (
            "inquiry",
            inquiry_id,
            json!({"project_id":project_id,"title":"Valve inquiry","item_ids":[],"supplier_ids":[supplier_id],"status":"open"}),
        ),
        (
            "quotation",
            quote_id,
            json!({"supplier_id":supplier_id,"product_id":product_id,"project_id":project_id,"inquiry_id":inquiry_id,"price":"250.001","min_qty":"2","currency":"CNY","tax_mode":"included","tax_rate":"13","unit_snapshot":"台","quoted_on":"2026-09-29","capture_mode":"standard","inquirer_name":"Buyer","inquiry_date":"2026-09-29","inquiry_precision":"date"}),
        ),
    ] {
        draft.records.push(RecordSnapshot {
            entity_type: kind.into(),
            entity_id: id,
            source_version: 3,
            data: serde_json::from_value(data).unwrap(),
        });
    }
    draft.validate().unwrap();
    let mut store = Store::open(":memory:").unwrap();
    let origin = Uuid::new_v4();
    store.publish(origin, draft.clone()).unwrap();
    let saved = store.get(origin, draft.publication_id, None).unwrap();
    assert_eq!(
        saved.draft.root_record().unwrap().data["price"],
        json!("250.001")
    );
    assert_eq!(
        store
            .search(&SearchQuery {
                q: "DN50".into(),
                supplier_id: Some(supplier_id),
                ..Default::default()
            })
            .unwrap()
            .len(),
        1
    );
    draft.records.retain(|r| r.entity_id != inquiry_id);
    assert!(draft.validate().is_err());
}

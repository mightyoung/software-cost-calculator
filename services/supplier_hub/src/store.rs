use crate::{
    error::{HubError, Result},
    model::{Publication, PublicationDraft},
};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::BTreeMap, path::Path, time::Duration};
use uuid::Uuid;

#[derive(Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct SearchQuery {
    pub q: String,
    pub kind: Option<String>,
    pub supplier_id: Option<Uuid>,
    pub include_withdrawn: bool,
    pub limit: u32,
    pub offset: u32,
}
impl Default for SearchQuery {
    fn default() -> Self {
        Self {
            q: String::new(),
            kind: None,
            supplier_id: None,
            include_withdrawn: false,
            limit: 20,
            offset: 0,
        }
    }
}
impl SearchQuery {
    pub fn validate(&self) -> Result<()> {
        if self.q.chars().count() > 200
            || self.limit == 0
            || self.limit > 100
            || self.offset > 1_000_000
            || self
                .kind
                .as_ref()
                .is_some_and(|k| k != "supplier" && k != "quotation")
        {
            return Err(HubError::Invalid("invalid search bounds or kind".into()));
        }
        Ok(())
    }
}
#[derive(Debug, Serialize)]
pub struct Receipt {
    pub origin: Uuid,
    pub publication_id: Uuid,
    pub revision: u32,
    pub duplicate: bool,
}
#[derive(Debug, Serialize)]
pub struct PublicationSummary {
    pub origin: Uuid,
    pub publication_id: Uuid,
    pub revision: u32,
    pub withdrawn: bool,
    pub kind: String,
    pub title: String,
    pub root_id: Uuid,
    pub context: BTreeMap<String, Value>,
}
#[derive(Debug, Serialize)]
pub struct StoreStatus {
    pub publication_count: u64,
    pub revision_count: u64,
    pub received_packages: u64,
    pub exported_versions: u64,
    pub tasks: BTreeMap<String, String>,
}
pub struct Store {
    connection: Connection,
}
// "SHUB" distinguishes this database from Dart client files and other SQLite applications.
const APPLICATION_ID: i32 = 0x5348_5542;
impl Store {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let mut connection = Connection::open(path)?;
        connection.busy_timeout(Duration::from_secs(5))?;
        let version: i64 = connection.pragma_query_value(None, "user_version", |r| r.get(0))?;
        if version > 1 {
            return Err(HubError::Invalid(
                "database schema newer than this hub".into(),
            ));
        }
        let application_id: i32 =
            connection.pragma_query_value(None, "application_id", |r| r.get(0))?;
        if version == 0 {
            let objects: i64 = connection.query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE name NOT GLOB 'sqlite_*'",
                [],
                |row| row.get(0),
            )?;
            if application_id != 0 || objects != 0 {
                return Err(HubError::Invalid(
                    "refusing to initialize a nonempty or foreign SQLite database".into(),
                ));
            }
        } else if version != 1 || application_id != APPLICATION_ID {
            return Err(HubError::Invalid(
                "database is not a supplier hub database".into(),
            ));
        }
        // Identity checks precede persistent PRAGMA writes, preserving unrelated databases.
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        if version == 0 {
            let tx = connection.transaction()?;
            tx.execute_batch("CREATE TABLE publications(origin TEXT NOT NULL,id TEXT NOT NULL,revision INTEGER NOT NULL,digest TEXT NOT NULL,payload TEXT NOT NULL,kind TEXT NOT NULL,title TEXT NOT NULL,search_text TEXT NOT NULL,supplier_id TEXT,withdrawn INTEGER NOT NULL,last_exported INTEGER,PRIMARY KEY(origin,id,revision)); CREATE INDEX publications_search ON publications(kind,supplier_id); CREATE INDEX publications_export ON publications(origin,last_exported); CREATE TABLE packages(id TEXT PRIMARY KEY,digest TEXT NOT NULL,origin TEXT NOT NULL,publication_id TEXT NOT NULL,revision INTEGER NOT NULL); CREATE TABLE tasks(name TEXT PRIMARY KEY,details TEXT NOT NULL); PRAGMA user_version=1;")?;
            tx.pragma_update(None, "application_id", APPLICATION_ID)?;
            tx.commit()?;
        }
        Ok(Self { connection })
    }
    pub fn publish(&mut self, origin: Uuid, mut draft: PublicationDraft) -> Result<Receipt> {
        draft.normalize();
        let publication = Publication { origin, draft };
        publication.validate()?;
        let digest = publication.digest()?;
        let tx = self
            .connection
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let duplicate = existing(&tx, &publication, &digest)?;
        if !duplicate {
            let current: Option<u32> = tx.query_row(
                "SELECT MAX(revision) FROM publications WHERE origin=? AND id=?",
                params![
                    origin.to_string(),
                    publication.draft.publication_id.to_string()
                ],
                |r| r.get(0),
            )?;
            if publication.draft.revision != current.unwrap_or(0) + 1 {
                return Err(HubError::Conflict(
                    "local publication requires the next revision".into(),
                ));
            }
            if let Some(payload)=tx.query_row("SELECT payload FROM publications WHERE origin=? AND id=? ORDER BY revision DESC LIMIT 1",params![origin.to_string(),publication.draft.publication_id.to_string()],|r|r.get::<_,String>(0)).optional()?{let previous:Publication=serde_json::from_str(&payload)?;if previous.draft.root!=publication.draft.root{return Err(HubError::Conflict("publication root is immutable".into()));}}
            insert(&tx, &publication, &digest)?;
        }
        tx.commit()?;
        Ok(receipt(&publication, duplicate))
    }
    pub fn import_package(
        &mut self,
        package_id: &str,
        digest: &str,
        publication: &Publication,
    ) -> Result<Receipt> {
        if package_id.is_empty()
            || package_id.len() > 200
            || digest.len() != 64
            || !digest.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Err(HubError::Invalid("invalid package identity".into()));
        }
        let mut publication = publication.clone();
        publication.draft.normalize();
        publication.validate()?;
        let publication_digest = publication.digest()?;
        let tx = self
            .connection
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let previous = tx
            .query_row(
                "SELECT digest,origin,publication_id,revision FROM packages WHERE id=?",
                [package_id],
                |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, u32>(3)?,
                    ))
                },
            )
            .optional()?;
        if let Some((prior, origin, id, revision)) = previous {
            if prior != digest
                || origin != publication.origin.to_string()
                || id != publication.draft.publication_id.to_string()
                || revision != publication.draft.revision
            {
                return Err(HubError::Conflict(
                    "package identity reused with different content".into(),
                ));
            }
            existing(&tx, &publication, &publication_digest)?;
            return Ok(receipt(&publication, true));
        }
        let duplicate = existing(&tx, &publication, &publication_digest)?;
        if !duplicate {
            if let Some(payload) = tx
                .query_row(
                    "SELECT payload FROM publications WHERE origin=? AND id=? LIMIT 1",
                    params![
                        publication.origin.to_string(),
                        publication.draft.publication_id.to_string()
                    ],
                    |r| r.get::<_, String>(0),
                )
                .optional()?
            {
                let previous: Publication = serde_json::from_str(&payload)?;
                if previous.draft.root != publication.draft.root {
                    return Err(HubError::Conflict("publication root is immutable".into()));
                }
            }
            insert(&tx, &publication, &publication_digest)?;
        }
        tx.execute(
            "INSERT INTO packages VALUES(?,?,?,?,?)",
            params![
                package_id,
                digest,
                publication.origin.to_string(),
                publication.draft.publication_id.to_string(),
                publication.draft.revision
            ],
        )?;
        tx.commit()?;
        Ok(receipt(&publication, duplicate))
    }
    pub fn get(&self, origin: Uuid, id: Uuid, revision: Option<u32>) -> Result<Publication> {
        let payload=self.connection.query_row("SELECT payload FROM publications WHERE origin=? AND id=? AND (? IS NULL OR revision=?) ORDER BY revision DESC LIMIT 1",params![origin.to_string(),id.to_string(),revision,revision],|r|r.get::<_,String>(0)).optional()?.ok_or(HubError::NotFound)?;
        Ok(serde_json::from_str(&payload)?)
    }
    pub fn search(&self, query: &SearchQuery) -> Result<Vec<PublicationSummary>> {
        query.validate()?;
        let pattern = format!(
            "%{}%",
            query
                .q
                .replace('!', "!!")
                .replace('%', "!%")
                .replace('_', "!_")
        );
        let mut stmt=self.connection.prepare("SELECT p.payload FROM publications p WHERE (? OR p.withdrawn=0) AND p.revision=(SELECT MAX(n.revision) FROM publications n WHERE n.origin=p.origin AND n.id=p.id) AND (? IS NULL OR p.kind=?) AND (? IS NULL OR p.supplier_id=?) AND p.search_text LIKE ? ESCAPE '!' ORDER BY p.title,p.origin,p.id LIMIT ? OFFSET ?")?;
        let supplier = query.supplier_id.map(|s| s.to_string());
        let rows = stmt.query_map(
            params![
                query.include_withdrawn,
                query.kind,
                query.kind,
                supplier,
                supplier,
                pattern,
                query.limit,
                query.offset
            ],
            |r| r.get::<_, String>(0),
        )?;
        rows.map(|row| summary(serde_json::from_str(&row?)?))
            .collect()
    }
    pub fn history(
        &self,
        origin: Uuid,
        id: Uuid,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<PublicationSummary>> {
        SearchQuery {
            limit,
            offset,
            ..Default::default()
        }
        .validate()?;
        let mut stmt=self.connection.prepare("SELECT payload FROM publications WHERE origin=? AND id=? ORDER BY revision DESC LIMIT ? OFFSET ?")?;
        let rows = stmt.query_map(
            params![origin.to_string(), id.to_string(), limit, offset],
            |r| r.get::<_, String>(0),
        )?;
        rows.map(|row| summary(serde_json::from_str(&row?)?))
            .collect()
    }
    pub fn pending_exports(
        &self,
        origin: Uuid,
        now: i64,
        retry_after: i64,
        limit: u32,
    ) -> Result<Vec<Publication>> {
        if retry_after < 0 || limit == 0 || limit > 1000 {
            return Err(HubError::Invalid("invalid export bounds".into()));
        }
        let mut stmt=self.connection.prepare("SELECT payload FROM publications WHERE origin=? AND (last_exported IS NULL OR last_exported<=?) ORDER BY COALESCE(last_exported,-1),rowid LIMIT ?")?;
        let rows = stmt.query_map(
            params![origin.to_string(), now.saturating_sub(retry_after), limit],
            |r| r.get::<_, String>(0),
        )?;
        rows.map(|row| Ok(serde_json::from_str(&row?)?)).collect()
    }
    pub fn mark_exported(&mut self, origin: Uuid, id: Uuid, revision: u32, now: i64) -> Result<()> {
        let n = self.connection.execute(
            "UPDATE publications SET last_exported=? WHERE origin=? AND id=? AND revision=?",
            params![now, origin.to_string(), id.to_string(), revision],
        )?;
        if n == 0 {
            return Err(HubError::NotFound);
        }
        Ok(())
    }
    pub fn get_task_status(&self, task: &str) -> Result<Option<String>> {
        Ok(self
            .connection
            .query_row("SELECT details FROM tasks WHERE name=?", [task], |r| {
                r.get(0)
            })
            .optional()?)
    }
    pub fn set_task_status(&mut self, task: &str, details: &str) -> Result<()> {
        if task.len() > 100 || details.len() > 4096 {
            return Err(HubError::Invalid("status too long".into()));
        }
        self.connection.execute("INSERT INTO tasks VALUES(?,?) ON CONFLICT(name) DO UPDATE SET details=excluded.details",params![task,details])?;
        Ok(())
    }
    pub fn status(&self) -> Result<StoreStatus> {
        let count = |sql: &str| -> Result<u64> {
            let value: i64 = self.connection.query_row(sql, [], |r| r.get(0))?;
            u64::try_from(value).map_err(|_| HubError::Invalid("negative database count".into()))
        };
        let mut stmt = self
            .connection
            .prepare("SELECT name,details FROM tasks ORDER BY name")?;
        let tasks = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<std::result::Result<BTreeMap<_, _>, _>>()?;
        Ok(StoreStatus {
            publication_count: count(
                "SELECT COUNT(*) FROM (SELECT origin,id FROM publications GROUP BY origin,id)",
            )?,
            revision_count: count("SELECT COUNT(*) FROM publications")?,
            received_packages: count("SELECT COUNT(*) FROM packages")?,
            exported_versions: count(
                "SELECT COUNT(*) FROM publications WHERE last_exported IS NOT NULL",
            )?,
            tasks,
        })
    }
    pub fn backup(&self, destination: &Path) -> Result<()> {
        // Reserve exclusively before SQLite opens it. Never overwrite an existing backup.
        let reserved = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(destination)?;
        drop(reserved);
        let result = (|| -> Result<()> {
            let mut target = Connection::open(destination)?;
            {
                let backup = rusqlite::backup::Backup::new(&self.connection, &mut target)?;
                backup.run_to_completion(128, Duration::from_millis(5), None)?;
            }
            let check: String = target.query_row("PRAGMA integrity_check", [], |r| r.get(0))?;
            if check != "ok" {
                return Err(HubError::Invalid("backup integrity check failed".into()));
            }
            drop(target);
            // FlushFileBuffers on Windows requires a handle opened for writing.
            std::fs::OpenOptions::new()
                .write(true)
                .open(destination)?
                .sync_all()?;
            Ok(())
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(destination);
        }
        result
    }
}
fn receipt(p: &Publication, duplicate: bool) -> Receipt {
    Receipt {
        origin: p.origin,
        publication_id: p.draft.publication_id,
        revision: p.draft.revision,
        duplicate,
    }
}
fn existing(connection: &Connection, p: &Publication, digest: &str) -> Result<bool> {
    let prior = connection
        .query_row(
            "SELECT digest FROM publications WHERE origin=? AND id=? AND revision=?",
            params![
                p.origin.to_string(),
                p.draft.publication_id.to_string(),
                p.draft.revision
            ],
            |r| r.get::<_, String>(0),
        )
        .optional()?;
    match prior {
        Some(prior) if prior != digest => Err(HubError::Conflict(
            "immutable publication revision already contains different data".into(),
        )),
        Some(_) => Ok(true),
        None => Ok(false),
    }
}
fn insert(connection: &Connection, p: &Publication, digest: &str) -> Result<()> {
    let root = p.draft.root_record()?;
    let supplier = if root.entity_type == "supplier" {
        Some(root.entity_id.to_string())
    } else {
        root.data
            .get("supplier_id")
            .and_then(Value::as_str)
            .map(str::to_owned)
    };
    let mut terms = String::new();
    for record in &p.draft.records {
        for field in [
            "name",
            "aliases",
            "categories",
            "brand",
            "model",
            "specification",
            "category",
            "code",
            "title",
            "notes",
        ] {
            if let Some(value) = record.data.get(field) {
                terms.push_str(&value.to_string());
                terms.push(' ');
            }
        }
    }
    connection.execute("INSERT INTO publications(origin,id,revision,digest,payload,kind,title,search_text,supplier_id,withdrawn) VALUES(?,?,?,?,?,?,?,?,?,?)",params![p.origin.to_string(),p.draft.publication_id.to_string(),p.draft.revision,digest,serde_json::to_string(p)?,p.draft.root.entity_type,p.draft.title(),terms,supplier,p.draft.withdrawn])?;
    Ok(())
}
fn summary(p: Publication) -> Result<PublicationSummary> {
    let root = p.draft.root_record()?;
    let mut context = BTreeMap::new();
    for key in [
        "rating",
        "rating_note",
        "price",
        "currency",
        "unit_snapshot",
        "tax_mode",
        "tax_rate",
        "min_qty",
        "quoted_on",
        "valid_until",
        "capture_mode",
        "price_basis",
        "inquiry_location",
        "inquirer_name",
        "inquiry_date",
        "project_id",
        "supplier_id",
    ] {
        if let Some(v) = root.data.get(key) {
            context.insert(key.into(), v.clone());
        }
    }
    if root.entity_type == "quotation" {
        for (reference, kind, field, key) in [
            ("supplier_id", "supplier", "name", "supplier_name"),
            ("product_id", "product", "model", "product_model"),
            ("product_id", "product", "brand", "product_brand"),
            ("project_id", "project", "name", "project_name"),
        ] {
            let related_id = root
                .data
                .get(reference)
                .and_then(Value::as_str)
                .and_then(|value| Uuid::parse_str(value).ok());
            if let Some(value) = p
                .draft
                .records
                .iter()
                .find(|record| record.entity_type == kind && Some(record.entity_id) == related_id)
                .and_then(|record| record.data.get(field))
            {
                context.insert(key.into(), value.clone());
            }
        }
    }
    Ok(PublicationSummary {
        origin: p.origin,
        publication_id: p.draft.publication_id,
        revision: p.draft.revision,
        withdrawn: p.draft.withdrawn,
        kind: p.draft.root.entity_type.clone(),
        title: p.draft.title(),
        root_id: p.draft.root.entity_id,
        context,
    })
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]
    use super::*;
    use crate::model::{RecordKey, RecordSnapshot};
    use serde_json::json;

    #[test]
    fn quotation_summary_resolves_contained_references_without_changing_payload() {
        let mut draft: PublicationDraft =
            serde_json::from_str(include_str!("../examples/supplier.json")).unwrap();
        let supplier_id = draft.root.entity_id;
        let product_id = Uuid::new_v4();
        let old_product_id = Uuid::new_v4();
        let project_id = Uuid::new_v4();
        let quotation_id = Uuid::new_v4();
        draft.root = RecordKey {
            entity_type: "quotation".into(),
            entity_id: quotation_id,
        };
        for (kind, id, data) in [
            (
                "product",
                old_product_id,
                json!({"name":"Old product", "unit":"set", "brand":"Wrong brand", "model":"Wrong model"}),
            ),
            (
                "product",
                product_id,
                json!({"name":"Valve", "unit":"set", "brand":"Valve brand", "model":"DN50", "merged_into":old_product_id}),
            ),
            (
                "project",
                project_id,
                json!({"name":"Factory retrofit", "currency":"CNY", "tax_mode":"included", "markup_rate":"0", "status":"active"}),
            ),
            (
                "quotation",
                quotation_id,
                json!({"supplier_id":supplier_id, "product_id":product_id, "project_id":project_id, "price":"12.345", "min_qty":"1", "currency":"CNY", "tax_mode":"included", "unit_snapshot":"set", "capture_mode":"historical"}),
            ),
        ] {
            draft.records.push(RecordSnapshot {
                entity_type: kind.into(),
                entity_id: id,
                source_version: 1,
                data: serde_json::from_value(data).unwrap(),
            });
        }
        let mut store = Store::open(":memory:").unwrap();
        let origin = Uuid::new_v4();
        store.publish(origin, draft.clone()).unwrap();
        let summaries = store.search(&SearchQuery::default()).unwrap();
        let context = &summaries[0].context;
        assert_eq!(context["supplier_name"], "示例设备供应商");
        assert_eq!(context["product_brand"], "Valve brand");
        assert_eq!(context["product_model"], "DN50");
        assert_eq!(context["project_name"], "Factory retrofit");
        assert_eq!(context["price"], "12.345");
        assert_eq!(context["supplier_id"], json!(supplier_id));
        assert_eq!(
            store.history(origin, draft.publication_id, 20, 0).unwrap()[0].context,
            *context
        );
        draft.normalize();
        assert_eq!(
            store.get(origin, draft.publication_id, None).unwrap().draft,
            draft
        );
        // Optional project and product labels remain absent when the snapshot omits them.
        let mut minimal = draft.clone();
        minimal
            .records
            .retain(|record| record.entity_type != "project");
        for record in &mut minimal.records {
            record.data.remove("project_id");
            if record.entity_id == product_id {
                record.data.remove("brand");
                record.data.remove("model");
            }
        }
        let context = summary(Publication {
            origin,
            draft: minimal,
        })
        .unwrap()
        .context;
        for key in ["project_name", "product_brand", "product_model"] {
            assert!(!context.contains_key(key));
        }
        assert_eq!(context["supplier_name"], "示例设备供应商");
    }
}

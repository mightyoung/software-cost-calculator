use std::{
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{
    error::{HubError, Result},
    model::Publication,
    store::Store,
};

pub const MAX_PACKAGE_BYTES: u64 = 4 * 1024 * 1024;
pub const MAX_PAYLOAD_BYTES: usize = 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ExchangeRole {
    Export,
    Import,
}

#[derive(Clone)]
pub struct ExchangeConfig {
    pub role: ExchangeRole,
    pub directory: PathBuf,
    pub trusted_origin: Option<Uuid>,
    pub interval_seconds: u64,
    pub resend_seconds: u64,
    pub max_files_per_tick: usize,
}

#[derive(Default, Debug, Serialize, Deserialize)]
pub struct ExchangeReport {
    pub scanned: usize,
    pub exported: usize,
    pub imported: usize,
    pub duplicates: usize,
    pub failed: usize,
    pub errors: Vec<String>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    protocol: u32,
    package_id: Uuid,
    origin: Uuid,
    payload_sha256: String,
    payload: String,
    hmac: String,
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn hex_tag(value: &str) -> Result<[u8; 32]> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(HubError::Invalid(
            "invalid exchange authentication tag".into(),
        ));
    }
    let mut output = [0_u8; 32];
    for (i, byte) in output.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&value[i * 2..i * 2 + 2], 16)
            .map_err(|_| HubError::Invalid("invalid authentication tag".into()))?;
    }
    Ok(output)
}

fn authenticated(envelope: &Envelope, key: &[u8]) -> Result<Hmac<Sha256>> {
    if key.len() < 32 {
        return Err(HubError::Invalid(
            "exchange key must contain at least 32 bytes".into(),
        ));
    }
    let mut mac = Hmac::<Sha256>::new_from_slice(key)
        .map_err(|_| HubError::Invalid("invalid exchange key".into()))?;
    mac.update(b"supplier-hub-package-v1\0");
    mac.update(&envelope.protocol.to_be_bytes());
    mac.update(envelope.package_id.as_bytes());
    mac.update(envelope.origin.as_bytes());
    mac.update(envelope.payload_sha256.as_bytes());
    mac.update(&(envelope.payload.len() as u64).to_be_bytes());
    mac.update(envelope.payload.as_bytes());
    Ok(mac)
}

pub fn encode_package(publication: &Publication, key: &[u8]) -> Result<Vec<u8>> {
    publication.validate()?;
    let payload = serde_json::to_string(publication)?;
    if payload.len() > MAX_PAYLOAD_BYTES {
        return Err(HubError::Invalid(
            "publication exceeds package payload limit".into(),
        ));
    }
    let mut envelope = Envelope {
        protocol: 1,
        package_id: Uuid::new_v4(),
        origin: publication.origin,
        payload_sha256: hex(&Sha256::digest(payload.as_bytes())),
        payload,
        hmac: String::new(),
    };
    envelope.hmac = hex(&authenticated(&envelope, key)?.finalize().into_bytes());
    let bytes = serde_json::to_vec(&envelope)?;
    if bytes.len() as u64 > MAX_PACKAGE_BYTES {
        return Err(HubError::Invalid("exchange package is too large".into()));
    }
    Ok(bytes)
}

pub fn decode_package(
    bytes: &[u8],
    trusted_origin: Uuid,
    key: &[u8],
) -> Result<(String, String, Publication)> {
    if bytes.len() as u64 > MAX_PACKAGE_BYTES {
        return Err(HubError::Invalid("exchange package is too large".into()));
    }
    let envelope: Envelope = serde_json::from_slice(bytes)?;
    if envelope.protocol != 1
        || envelope.package_id.get_version_num() != 4
        || envelope.origin != trusted_origin
    {
        return Err(HubError::Invalid(
            "unsupported package protocol or untrusted origin".into(),
        ));
    }
    if envelope.payload.len() > MAX_PAYLOAD_BYTES {
        return Err(HubError::Invalid("exchange payload is too large".into()));
    }
    authenticated(&envelope, key)?
        .verify_slice(&hex_tag(&envelope.hmac)?)
        .map_err(|_| HubError::Invalid("exchange authentication failed".into()))?;
    if hex(&Sha256::digest(envelope.payload.as_bytes())) != envelope.payload_sha256 {
        return Err(HubError::Invalid("exchange content digest mismatch".into()));
    }
    let publication: Publication = serde_json::from_str(&envelope.payload)?;
    publication.validate()?;
    if publication.origin != envelope.origin {
        return Err(HubError::Invalid("publication origin mismatch".into()));
    }
    Ok((
        envelope.package_id.to_string(),
        envelope.payload_sha256,
        publication,
    ))
}

pub fn run_once(
    store: &mut Store,
    center_id: Uuid,
    config: &ExchangeConfig,
    key: &[u8],
) -> Result<ExchangeReport> {
    if !(1..=1000).contains(&config.max_files_per_tick)
        || config.resend_seconds == 0
        || config.resend_seconds > 31_536_000
    {
        return Err(HubError::Invalid("invalid exchange limits".into()));
    }
    if key.len() < 32 {
        return Err(HubError::Invalid(
            "exchange key must contain at least 32 bytes".into(),
        ));
    }
    let mut report = match config.role {
        ExchangeRole::Export => export_tick(store, center_id, config, key)?,
        ExchangeRole::Import => import_tick(store, center_id, config, key)?,
    };
    // Status has a byte budget. Multibyte filenames must not turn successful imports into failures.
    while serde_json::to_vec(&report)?.len() > 4000 {
        report.errors.pop();
    }
    store.set_task_status("directory_exchange", &serde_json::to_string(&report)?)?;
    Ok(report)
}

fn export_tick(
    store: &mut Store,
    center_id: Uuid,
    config: &ExchangeConfig,
    key: &[u8],
) -> Result<ExchangeReport> {
    fs::create_dir_all(&config.directory)?;
    // A separate sibling directory keeps unfinished files outside the watched outbox.
    let canonical = config.directory.canonicalize()?;
    let parent = canonical
        .parent()
        .ok_or_else(|| HubError::Invalid("outbox cannot be filesystem root".into()))?;
    let staging = parent.join(format!(".supplier-hub-{center_id}-staging"));
    fs::create_dir_all(&staging)?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| HubError::Invalid("system clock predates Unix epoch".into()))?
        .as_secs() as i64;
    let items = store.pending_exports(
        center_id,
        now,
        config.resend_seconds as i64,
        config.max_files_per_tick as u32,
    )?;
    let mut report = ExchangeReport::default();
    for publication in items {
        let attempt = (|| -> Result<()> {
            let bytes = encode_package(&publication, key)?;
            let mut file = tempfile::NamedTempFile::new_in(&staging)?;
            file.write_all(&bytes)?;
            file.as_file().sync_all()?;
            // A fresh attempt name forces directory copiers to notice deliberate resends.
            let target = canonical.join(format!("{}-{}.hubpkg", center_id, Uuid::new_v4()));
            file.persist_noclobber(&target)
                .map_err(|error| HubError::Io(error.error))?;
            sync_directory(&canonical)?;
            store.mark_exported(
                center_id,
                publication.draft.publication_id,
                publication.draft.revision,
                now,
            )?;
            Ok(())
        })();
        match attempt {
            Ok(()) => report.exported += 1,
            Err(error) => {
                report_error(&mut report, "export", &error);
                break;
            }
        }
    }
    Ok(report)
}

fn import_tick(
    store: &mut Store,
    center_id: Uuid,
    config: &ExchangeConfig,
    key: &[u8],
) -> Result<ExchangeReport> {
    let origin = config
        .trusted_origin
        .filter(|id| *id != center_id)
        .ok_or_else(|| HubError::Invalid("import requires a distinct trusted origin".into()))?;
    let cursor = store.get_task_status("import_cursor")?.unwrap_or_default();
    // Keep only the next bounded batch in memory, including wrapped candidates.
    let mut after = std::collections::BTreeSet::new();
    let mut before = std::collections::BTreeSet::new();
    for entry in fs::read_dir(&config.directory)? {
        let entry = entry?;
        if !entry.file_type()?.is_file()
            || entry.path().extension().is_none_or(|ext| ext != "hubpkg")
        {
            continue;
        }
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        let set = if name > cursor {
            &mut after
        } else {
            &mut before
        };
        set.insert(name);
        if set.len() > config.max_files_per_tick {
            set.pop_last();
        }
    }
    let names: Vec<_> = after
        .into_iter()
        .chain(before)
        .take(config.max_files_per_tick)
        .collect();
    let mut report = ExchangeReport::default();
    for name in names {
        report.scanned += 1;
        let attempt = (|| -> Result<bool> {
            let path = config.directory.join(&name);
            // Do not follow symlinks; this check is not a sandbox for a malicious filesystem owner.
            if !fs::symlink_metadata(&path)?.file_type().is_file() {
                return Err(HubError::Invalid(
                    "inbox entry is not a regular file".into(),
                ));
            }
            let file = File::open(&path)?;
            if !file.metadata()?.is_file() {
                return Err(HubError::Invalid(
                    "inbox entry is not a regular file".into(),
                ));
            }
            let mut bytes = Vec::new();
            file.take(MAX_PACKAGE_BYTES + 1).read_to_end(&mut bytes)?;
            // The owned bounded byte snapshot is validated, never the changing file itself.
            let (package_id, digest, publication) = decode_package(&bytes, origin, key)?;
            Ok(store
                .import_package(&package_id, &digest, &publication)?
                .duplicate)
        })();
        match attempt {
            Ok(true) => report.duplicates += 1,
            Ok(false) => report.imported += 1,
            Err(error) => report_error(&mut report, &name, &error),
        }
        // Poison/partial files do not starve later entries; the cursor wraps on subsequent ticks.
        store.set_task_status("import_cursor", &name)?;
    }
    Ok(report)
}

fn report_error(report: &mut ExchangeReport, name: &str, error: &HubError) {
    report.failed += 1;
    if report.errors.len() < 10 {
        report.errors.push(format!(
            "{}: {}",
            name.chars().take(100).collect::<String>(),
            error.to_string().chars().take(250).collect::<String>()
        ));
    }
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<()> {
    File::open(path)?.sync_all()?;
    Ok(())
}
#[cfg(not(unix))]
fn sync_directory(_path: &Path) -> Result<()> {
    Ok(())
}

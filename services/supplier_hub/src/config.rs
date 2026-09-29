use std::{
    net::SocketAddr,
    path::{Path, PathBuf},
};

use serde::Deserialize;
use uuid::Uuid;

use crate::{
    error::{HubError, Result},
    exchange::{ExchangeConfig, ExchangeRole},
};

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub center_id: Uuid,
    #[serde(default = "default_bind")]
    pub bind: SocketAddr,
    pub database: PathBuf,
    #[serde(default)]
    pub sync: SyncConfig,
}

#[derive(Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct SyncConfig {
    pub enabled: bool,
    pub role: ExchangeRole,
    pub directory: PathBuf,
    pub trusted_origin: Option<Uuid>,
    pub interval_seconds: u64,
    pub resend_seconds: u64,
    pub max_files_per_tick: usize,
}

impl Default for SyncConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            role: ExchangeRole::Export,
            directory: PathBuf::new(),
            trusted_origin: None,
            interval_seconds: 30,
            resend_seconds: 86400,
            max_files_per_tick: 50,
        }
    }
}

// Deliberately no Debug/Serialize: credentials must never appear in status/logs.
#[derive(Clone)]
pub struct Secrets {
    pub api_token: Option<String>,
    pub sync_key: Option<Vec<u8>>,
}

impl Secrets {
    pub fn from_env() -> Result<Self> {
        fn optional(name: &str) -> Result<Option<String>> {
            match std::env::var(name) {
                Ok(value) => Ok(Some(value)),
                Err(std::env::VarError::NotPresent) => Ok(None),
                Err(_) => Err(HubError::Invalid(format!("{name} must be UTF-8"))),
            }
        }
        Ok(Self {
            api_token: optional("HUB_API_TOKEN")?,
            sync_key: optional("HUB_SYNC_KEY")?.map(String::into_bytes),
        })
    }
}

impl Config {
    pub fn load(path: &Path) -> Result<Self> {
        let contents = std::fs::read_to_string(path)?;
        let mut value: Self = toml::from_str(&contents)
            .map_err(|_| HubError::Invalid("invalid hub configuration".into()))?;
        let base = path.parent().unwrap_or_else(|| Path::new("."));
        if value.database.is_relative() {
            value.database = base.join(&value.database);
        }
        if !value.sync.directory.as_os_str().is_empty() && value.sync.directory.is_relative() {
            value.sync.directory = base.join(&value.sync.directory);
        }
        Ok(value)
    }

    pub fn validate_storage(&self) -> Result<()> {
        if self.center_id.get_version_num() != 4
            || self.center_id.get_variant() != uuid::Variant::RFC4122
            || self.database.as_os_str().is_empty()
        {
            return Err(HubError::Invalid(
                "center_id must be UUID v4 and database must be configured".into(),
            ));
        }
        Ok(())
    }

    pub fn validate(&self, secrets: &Secrets) -> Result<()> {
        self.validate_storage()?;
        if secrets
            .api_token
            .as_ref()
            .is_some_and(|s| s.len() < 32 || s.chars().any(char::is_whitespace))
        {
            return Err(HubError::Invalid(
                "HUB_API_TOKEN must contain at least 32 bytes and no whitespace".into(),
            ));
        }
        if !self.bind.ip().is_loopback() && secrets.api_token.is_none() {
            return Err(HubError::Invalid(
                "non-loopback listening requires HUB_API_TOKEN".into(),
            ));
        }
        if !self.sync.enabled {
            return Ok(());
        }
        if self.sync.directory.as_os_str().is_empty()
            || self.sync.interval_seconds == 0
            || self.sync.interval_seconds > 86400
            || self.sync.resend_seconds == 0
            || self.sync.resend_seconds > 31_536_000
            || !(1..=1000).contains(&self.sync.max_files_per_tick)
        {
            return Err(HubError::Invalid(
                "invalid sync directory, interval, resend interval, or batch limit".into(),
            ));
        }
        if secrets.sync_key.as_ref().is_none_or(|k| k.len() < 32) {
            return Err(HubError::Invalid(
                "enabled sync requires HUB_SYNC_KEY with at least 32 bytes".into(),
            ));
        }
        if self.sync.role == ExchangeRole::Import
            && self.sync.trusted_origin.is_none_or(|id| {
                id == self.center_id
                    || id.get_version_num() != 4
                    || id.get_variant() != uuid::Variant::RFC4122
            })
        {
            return Err(HubError::Invalid(
                "import requires a distinct UUID v4 trusted_origin".into(),
            ));
        }
        // The inbox must already exist; the exporter can create its own outbox.
        if self.sync.role == ExchangeRole::Import && !self.sync.directory.is_dir() {
            return Err(HubError::Invalid(
                "import directory must already exist".into(),
            ));
        }
        Ok(())
    }

    pub fn exchange_config(&self) -> ExchangeConfig {
        ExchangeConfig {
            role: self.sync.role.clone(),
            directory: self.sync.directory.clone(),
            trusted_origin: self.sync.trusted_origin,
            interval_seconds: self.sync.interval_seconds,
            resend_seconds: self.sync.resend_seconds,
            max_files_per_tick: self.sync.max_files_per_tick,
        }
    }
}

fn default_bind() -> SocketAddr {
    SocketAddr::from(([127, 0, 0, 1], 8080))
}

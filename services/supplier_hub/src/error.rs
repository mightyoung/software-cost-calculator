use thiserror::Error;

pub type Result<T> = std::result::Result<T, HubError>;

#[derive(Debug, Error)]
pub enum HubError {
    #[error("{0}")]
    Invalid(String),
    #[error("{0}")]
    Conflict(String),
    #[error("record not found")]
    NotFound,
    #[error("I/O failure: {0}")]
    Io(#[from] std::io::Error),
    #[error("database failure: {0}")]
    Sql(#[from] rusqlite::Error),
    #[error("invalid JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("service is unavailable")]
    Unavailable,
}

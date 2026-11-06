use thiserror::Error;

pub type CoreResult<T> = Result<T, CoreError>;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("invalid cryptographic key or signature: {0}")]
    Crypto(String),

    #[error("event id mismatch: expected {expected}, got {actual}")]
    EventIdMismatch { expected: String, actual: String },

    #[error("permission denied for member '{member_id}': missing capability '{capability}'")]
    PermissionDenied {
        member_id: String,
        capability: String,
    },

    #[error("policy error: {0}")]
    Policy(String),

    #[error("financial validation failed: {0}")]
    FinancialValidation(String),

    #[error("conflict error: {0}")]
    Conflict(String),

    #[error("settlement error: {0}")]
    Settlement(String),

    #[error("sync package error: {0}")]
    SyncPackage(String),

    #[error("resource limit exceeded: {0}")]
    LimitExceeded(String),

    #[error("not found: {0}")]
    NotFound(String),

    #[error("database error: {0}")]
    Database(#[from] rusqlite::Error),

    #[error("serialization error: {0}")]
    Serialization(#[from] serde_json::Error),
}

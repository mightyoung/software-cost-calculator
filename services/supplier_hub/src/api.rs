use std::sync::{Arc, Mutex};

use axum::{
    Json, Router,
    extract::Request,
    extract::{DefaultBodyLimit, Path, Query, State},
    http::{HeaderValue, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{
    config::Config,
    error::{HubError, Result},
    model::{Publication, PublicationDraft},
    store::{SearchQuery, Store},
};

#[derive(Clone)]
pub struct AppState {
    pub store: Arc<Mutex<Store>>,
    pub config: Arc<Config>,
    // Hashed credential avoids keeping it in debug responses and uses constant-time comparison.
    pub token_hash: Option<[u8; 32]>,
    database_slots: Arc<tokio::sync::Semaphore>,
}

impl AppState {
    pub fn new(store: Store, config: Config, token: Option<&str>) -> Self {
        Self {
            store: Arc::new(Mutex::new(store)),
            config: Arc::new(config),
            token_hash: token.map(|s| Sha256::digest(s.as_bytes()).into()),
            database_slots: Arc::new(tokio::sync::Semaphore::new(16)),
        }
    }

    pub async fn database<T, F>(&self, action: F) -> Result<T>
    where
        T: Send + 'static,
        F: FnOnce(&mut Store) -> Result<T> + Send + 'static,
    {
        let store = Arc::clone(&self.store);
        let permit = Arc::clone(&self.database_slots)
            .try_acquire_owned()
            .map_err(|_| HubError::Unavailable)?;
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let mut guard = store.lock().map_err(|_| HubError::Unavailable)?;
            action(&mut guard)
        })
        .await
        .map_err(|_| HubError::Unavailable)?
    }
}

pub fn router(state: AppState) -> Router {
    let protected = Router::new()
        .route("/v1/publications", post(publish).get(search))
        .route("/v1/publications/preview", post(preview))
        .route("/v1/publications/{origin}/{id}", get(publication))
        .route("/v1/publications/{origin}/{id}/history", get(history))
        .route("/v1/status", get(status))
        .route_layer(middleware::from_fn_with_state(state.clone(), authenticate));
    Router::new()
        .route("/healthz", get(|| async { Json(json!({"status":"ok"})) }))
        .merge(crate::web::router())
        .merge(protected)
        .layer(DefaultBodyLimit::max(1024 * 1024))
        .layer(middleware::from_fn(no_cache))
        .with_state(state)
}

async fn no_cache(request: Request, next: Next) -> Response {
    let mut response = next.run(request).await;
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response.headers_mut().insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    response
}

async fn authenticate(State(state): State<AppState>, request: Request, next: Next) -> Response {
    if let Some(expected) = state.token_hash {
        let supplied = request
            .headers()
            .get(header::AUTHORIZATION)
            .and_then(|h| h.to_str().ok())
            .and_then(|s| s.strip_prefix("Bearer "));
        let Some(token) = supplied else {
            return unauthorized();
        };
        // HMAC verification provides a constant-time check without introducing another dependency.
        use hmac::{Hmac, Mac};
        let supplied_hash = Sha256::digest(token.as_bytes());
        let Ok(mut left) = Hmac::<Sha256>::new_from_slice(b"supplier-hub-api-token-comparison")
        else {
            return unauthorized();
        };
        left.update(&expected);
        let tag = left.finalize().into_bytes();
        let Ok(mut right) = Hmac::<Sha256>::new_from_slice(b"supplier-hub-api-token-comparison")
        else {
            return unauthorized();
        };
        right.update(&supplied_hash);
        if right.verify_slice(&tag).is_err() {
            return unauthorized();
        }
    }
    next.run(request).await
}

fn unauthorized() -> Response {
    (
        StatusCode::UNAUTHORIZED,
        [(header::WWW_AUTHENTICATE, "Bearer")],
        Json(json!({"error":"unauthorized"})),
    )
        .into_response()
}

async fn publish(
    State(state): State<AppState>,
    body: std::result::Result<Json<PublicationDraft>, axum::extract::rejection::JsonRejection>,
) -> Result<Response> {
    let Json(draft) = match body {
        Ok(value) => value,
        Err(rejection) => {
            return Ok((
                rejection.status(),
                Json(json!({"error":"invalid_publication_body"})),
            )
                .into_response());
        }
    };
    let origin = state.config.center_id;
    let receipt = state.database(move |db| db.publish(origin, draft)).await?;
    Ok((
        if receipt.duplicate {
            StatusCode::OK
        } else {
            StatusCode::CREATED
        },
        Json(receipt),
    )
        .into_response())
}

async fn preview(
    State(state): State<AppState>,
    body: std::result::Result<Json<PublicationDraft>, axum::extract::rejection::JsonRejection>,
) -> Result<Response> {
    let Json(mut draft) = match body {
        Ok(value) => value,
        Err(rejection) => {
            return Ok((
                rejection.status(),
                Json(json!({"error":"invalid_publication_body"})),
            )
                .into_response());
        }
    };
    draft.normalize();
    let publication = Publication {
        origin: state.config.center_id,
        draft,
    };
    publication.validate()?;
    Ok(Json(json!({
        "title": publication.draft.title(),
        "record_count": publication.draft.records.len(),
        "draft": publication.draft,
    }))
    .into_response())
}

async fn search(
    State(state): State<AppState>,
    Query(query): Query<SearchQuery>,
) -> Result<Response> {
    let publications = state.database(move |db| db.search(&query)).await?;
    Ok(Json(json!({"items": publications})).into_response())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct VersionQuery {
    revision: Option<u32>,
}

async fn publication(
    State(state): State<AppState>,
    Path((origin, id)): Path<(Uuid, Uuid)>,
    Query(query): Query<VersionQuery>,
) -> Result<Response> {
    let value = state
        .database(move |db| db.get(origin, id, query.revision))
        .await?;
    Ok(Json(value).into_response())
}

#[derive(Deserialize)]
#[serde(default, deny_unknown_fields)]
struct Page {
    limit: u32,
    offset: u32,
}
impl Default for Page {
    fn default() -> Self {
        Self {
            limit: 20,
            offset: 0,
        }
    }
}

async fn history(
    State(state): State<AppState>,
    Path((origin, id)): Path<(Uuid, Uuid)>,
    Query(page): Query<Page>,
) -> Result<Response> {
    if !(1..=100).contains(&page.limit) || page.offset > 1_000_000 {
        return Err(HubError::Invalid("invalid pagination".into()));
    }
    let values = state
        .database(move |db| db.history(origin, id, page.limit, page.offset))
        .await?;
    Ok(Json(json!({"items":values})).into_response())
}

async fn status(State(state): State<AppState>) -> Result<Response> {
    let data = state.database(|db| db.status()).await?;
    Ok(Json(
        json!({"center_id":state.config.center_id,"sync_enabled":state.config.sync.enabled,
        "sync_role":state.config.sync.role,
        "sync_interval_seconds":state.config.sync.interval_seconds,
        "resend_seconds":state.config.sync.resend_seconds,
        "max_files_per_tick":state.config.sync.max_files_per_tick,
        "trusted_origin":state.config.sync.trusted_origin,
        "authentication_required":state.token_hash.is_some(),
        "remote_receipt_available":false,"store":data}),
    )
    .into_response())
}

impl IntoResponse for HubError {
    fn into_response(self) -> Response {
        let (status, code, message) = match self {
            Self::Invalid(message) => (
                StatusCode::UNPROCESSABLE_ENTITY,
                "invalid_publication",
                message,
            ),
            Self::Conflict(message) => (StatusCode::CONFLICT, "publication_conflict", message),
            Self::NotFound => (
                StatusCode::NOT_FOUND,
                "not_found",
                "record not found".to_owned(),
            ),
            error => {
                // Internal details are deliberately not included in HTTP output.
                tracing::error!(error = %error, "hub operation failed");
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "unavailable",
                    "service temporarily unavailable".to_owned(),
                )
            }
        };
        (status, Json(json!({"error":code,"message":message}))).into_response()
    }
}

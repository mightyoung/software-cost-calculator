#![allow(clippy::unwrap_used)]

use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use supplier_hub::{
    api::{AppState, router},
    config::{Config, Secrets},
    store::Store,
};
use tower::ServiceExt;

const TOKEN: &str = "test-only-api-token-at-least-32-bytes";
fn config() -> Config {
    toml::from_str(include_str!("../examples/local.toml")).unwrap()
}
fn request(method: &str, path: &str, body: String, token: Option<&str>) -> Request<Body> {
    let mut builder = Request::builder()
        .method(method)
        .uri(path)
        .header("content-type", "application/json");
    if let Some(token) = token {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    builder.body(Body::from(body)).unwrap()
}

#[tokio::test]
async fn authenticated_publication_search_conflict_and_body_limit() {
    let state = AppState::new(Store::open(":memory:").unwrap(), config(), Some(TOKEN));
    let app = router(state.clone());
    let payload = include_str!("../examples/supplier.json").to_owned();
    for token in [None, Some("bad")] {
        assert_eq!(
            app.clone()
                .oneshot(request("POST", "/v1/publications", payload.clone(), token))
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
    }
    let first = app
        .clone()
        .oneshot(request(
            "POST",
            "/v1/publications",
            payload.clone(),
            Some(TOKEN),
        ))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::CREATED);
    assert_eq!(first.headers()["cache-control"], "no-store");
    assert_eq!(
        app.clone()
            .oneshot(request(
                "POST",
                "/v1/publications",
                payload.clone(),
                Some(TOKEN)
            ))
            .await
            .unwrap()
            .status(),
        StatusCode::OK
    );
    assert_eq!(
        app.clone()
            .oneshot(request(
                "POST",
                "/v1/publications",
                payload.replace("示例设备供应商", "另一个名称"),
                Some(TOKEN)
            ))
            .await
            .unwrap()
            .status(),
        StatusCode::CONFLICT
    );
    let found = app
        .clone()
        .oneshot(request(
            "GET",
            "/v1/publications?kind=supplier",
            String::new(),
            Some(TOKEN),
        ))
        .await
        .unwrap();
    let value: serde_json::Value =
        serde_json::from_slice(&found.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(value["items"].as_array().unwrap().len(), 1);
    assert_eq!(
        app.clone()
            .oneshot(request(
                "GET",
                "/v1/publications?limit=1001",
                String::new(),
                Some(TOKEN)
            ))
            .await
            .unwrap()
            .status(),
        StatusCode::UNPROCESSABLE_ENTITY
    );
    assert_eq!(
        app.clone()
            .oneshot(request(
                "POST",
                "/v1/publications",
                " ".repeat(1024 * 1024 + 1),
                Some(TOKEN)
            ))
            .await
            .unwrap()
            .status(),
        StatusCode::PAYLOAD_TOO_LARGE
    );
    let mut unknown: serde_json::Value = serde_json::from_str(&payload).unwrap();
    unknown["api_key"] = serde_json::json!("must-not-be-stored");
    assert_eq!(
        app.clone()
            .oneshot(request(
                "POST",
                "/v1/publications",
                unknown.to_string(),
                Some(TOKEN)
            ))
            .await
            .unwrap()
            .status(),
        StatusCode::UNPROCESSABLE_ENTITY
    );
    let health = app
        .oneshot(request("GET", "/healthz", String::new(), None))
        .await
        .unwrap();
    assert_eq!(health.status(), StatusCode::OK);
    assert_eq!(
        state
            .database(|db| db.status())
            .await
            .unwrap()
            .revision_count,
        1
    );
}

#[test]
fn remote_bind_requires_credential_and_disabled_sync_needs_no_directory() {
    let mut config = config();
    let secrets = Secrets {
        api_token: None,
        sync_key: None,
    };
    config.validate(&secrets).unwrap();
    config.bind = "0.0.0.0:8080".parse().unwrap();
    assert!(config.validate(&secrets).is_err());
    let mut secrets = Secrets {
        api_token: Some(TOKEN.into()),
        sync_key: None,
    };
    config.validate(&secrets).unwrap();
    config.sync.enabled = true;
    assert!(config.validate(&secrets).is_err());
    config.sync.directory = "/tmp/hub-out".into();
    secrets.sync_key = Some(vec![1; 32]);
    config.validate(&secrets).unwrap();
    config.sync.interval_seconds = 0;
    assert!(config.validate(&secrets).is_err());
}

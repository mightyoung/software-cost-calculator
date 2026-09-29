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
        .header("host", "localhost:8080")
        .header("content-type", "application/json");
    if let Some(token) = token {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    builder.body(Body::from(body)).unwrap()
}

fn local_request(path: &str, hosts: &[&str], origins: &[&str]) -> Request<Body> {
    let mut request = request(
        "POST",
        path,
        include_str!("../examples/supplier.json").into(),
        None,
    );
    request.headers_mut().remove("host");
    for host in hosts {
        request.headers_mut().append("host", host.parse().unwrap());
    }
    for origin in origins {
        request
            .headers_mut()
            .append("origin", origin.parse().unwrap());
    }
    request
}

#[tokio::test]
async fn tokenless_requests_reject_foreign_or_ambiguous_authorities_without_writes() {
    let state = AppState::new(Store::open(":memory:").unwrap(), config(), None);
    let app = router(state.clone());
    let cases: &[(&[&str], &[&str])] = &[
        (&[], &[]),
        (&["attacker.example:8080"], &[]),
        (&["localhost.attacker.example:8080"], &[]),
        (&["localhost:8080", "localhost:8080"], &[]),
        (&["localhost:8080,attacker.example"], &[]),
        (&["localhost:8081"], &[]),
        (&["localhost"], &[]),
        (&["127.0.0.2:8080"], &[]),
        (&["user@localhost:8080"], &[]),
        (&["localhost:8080/path"], &[]),
        (&["localhost:8080?query"], &[]),
        (&["localhost:8080#fragment"], &[]),
        (&["localhost:"], &[]),
        (&["localhost:99999"], &[]),
        (&["localhost:+8080"], &[]),
        (&["localhost.:8080"], &[]),
        (&["[127.0.0.1]:8080"], &[]),
        (&["localhost:8080"], &["null"]),
        (&["localhost:8080"], &["http://attacker.example"]),
        (&["localhost:8080"], &["http://localhost:8081"]),
        (&["localhost:8080"], &["https://localhost:8080"]),
        (&["localhost:8080"], &["http://127.0.0.1:8080"]),
        (
            &["localhost:8080"],
            &["http://localhost:8080.attacker.example"],
        ),
        (&["localhost:8080"], &["http://user@localhost:8080"]),
        (&["localhost:8080"], &["http://localhost:8080/"]),
        (&["localhost:8080"], &["http://localhost:8080?query"]),
        (&["localhost:8080"], &["http://localhost:8080#fragment"]),
        (
            &["localhost:8080"],
            &["http://localhost:8080 http://attacker.example"],
        ),
        (
            &["localhost:8080"],
            &["http://localhost:8080", "http://localhost:8080"],
        ),
    ];
    for (hosts, origins) in cases {
        let mut request = local_request("/v1/publications", hosts, origins);
        request
            .headers_mut()
            .insert("x-forwarded-host", "localhost:8080".parse().unwrap());
        request
            .headers_mut()
            .insert("x-forwarded-proto", "http".parse().unwrap());
        let response = app.clone().oneshot(request).await.unwrap();
        assert_eq!(
            response.status(),
            StatusCode::FORBIDDEN,
            "hosts={hosts:?}, origins={origins:?}"
        );
    }
    for uri in [
        "http://attacker.example:8080/v1/publications",
        "http://localhost:8081/v1/publications",
        "http://127.0.0.1:8080/v1/publications",
        "https://localhost:8080/v1/publications",
        "http://user@localhost:8080/v1/publications",
    ] {
        let response = app
            .clone()
            .oneshot(local_request(uri, &["localhost:8080"], &[]))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN, "uri={uri}");
    }
    for path in ["/v1/status", "/v1/publications"] {
        let mut request = request("GET", path, String::new(), None);
        request
            .headers_mut()
            .insert("host", "attacker.example:8080".parse().unwrap());
        assert_eq!(
            app.clone().oneshot(request).await.unwrap().status(),
            StatusCode::FORBIDDEN
        );
    }
    let status = state.database(|db| db.status()).await.unwrap();
    assert_eq!(status.revision_count, 0);
    assert_eq!(status.received_packages, 0);
    assert!(status.tasks.is_empty());
}

#[tokio::test]
async fn tokenless_same_origin_and_native_requests_support_ipv4_ipv6_and_default_port() {
    for (bind, host, origin) in [
        ("127.0.0.1:8080", "localhost:8080", None),
        (
            "127.0.0.1:8080",
            "127.0.0.1:8080",
            Some("http://127.0.0.1:8080"),
        ),
        (
            "127.0.0.1:8080",
            "LOCALHOST:8080",
            Some("http://localhost:8080"),
        ),
        ("[::1]:8080", "[::1]:8080", Some("http://[::1]:8080")),
        ("[::1]:8080", "localhost:8080", None),
        ("127.0.0.1:80", "localhost", Some("http://localhost")),
        ("127.0.0.1:80", "localhost:80", Some("http://localhost")),
    ] {
        let mut config = config();
        config.bind = bind.parse().unwrap();
        let state = AppState::new(Store::open(":memory:").unwrap(), config, None);
        let origins: Vec<_> = origin.into_iter().collect();
        let response = router(state.clone())
            .oneshot(local_request("/v1/publications", &[host], &origins))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::CREATED,
            "bind={bind}, host={host}"
        );
        assert_eq!(
            state
                .database(|db| db.status())
                .await
                .unwrap()
                .revision_count,
            1
        );
    }
    let app = router(AppState::new(
        Store::open(":memory:").unwrap(),
        config(),
        None,
    ));
    assert_eq!(
        app.oneshot(local_request(
            "http://localhost:8080/v1/publications",
            &["localhost:8080"],
            &["http://localhost:8080"]
        ))
        .await
        .unwrap()
        .status(),
        StatusCode::CREATED
    );
}

#[tokio::test]
async fn tokenless_unvalidated_remote_or_unresolved_bind_fails_closed() {
    for bind in ["0.0.0.0:8080", "192.0.2.1:8080", "[::]:8080", "127.0.0.1:0"] {
        let mut config = config();
        config.bind = bind.parse().unwrap();
        let state = AppState::new(Store::open(":memory:").unwrap(), config, None);
        let app = router(state.clone());
        assert_eq!(
            app.clone()
                .oneshot(local_request("/v1/publications", &["localhost:8080"], &[]))
                .await
                .unwrap()
                .status(),
            StatusCode::FORBIDDEN,
            "bind={bind}"
        );
        assert_eq!(
            state
                .database(|db| db.status())
                .await
                .unwrap()
                .revision_count,
            0
        );
        for path in ["/healthz", "/admin/"] {
            let mut request = request("GET", path, String::new(), None);
            request.headers_mut().remove("host");
            assert_eq!(
                app.clone().oneshot(request).await.unwrap().status(),
                StatusCode::OK
            );
        }
    }
}

#[tokio::test]
async fn token_mode_retains_remote_proxy_access() {
    let mut config = config();
    config.bind = "0.0.0.0:8080".parse().unwrap();
    let app = router(AppState::new(
        Store::open(":memory:").unwrap(),
        config,
        Some(TOKEN),
    ));
    let mut request = request("GET", "/v1/status", String::new(), Some(TOKEN));
    request
        .headers_mut()
        .insert("host", "hub.example".parse().unwrap());
    request
        .headers_mut()
        .insert("origin", "https://hub.example".parse().unwrap());
    assert_eq!(app.oneshot(request).await.unwrap().status(), StatusCode::OK);
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

async fn response_json(response: axum::response::Response) -> serde_json::Value {
    serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes()).unwrap()
}

#[tokio::test]
async fn admin_shell_assets_are_public_exact_routes_with_restrictive_headers() {
    let app = router(AppState::new(
        Store::open(":memory:").unwrap(),
        config(),
        Some(TOKEN),
    ));
    for path in ["/", "/admin", "/admin/"] {
        let response = app
            .clone()
            .oneshot(request("GET", path, String::new(), None))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.headers()["content-type"],
            "text/html; charset=utf-8"
        );
        assert_eq!(response.headers()["cache-control"], "no-store");
        assert_eq!(response.headers()["x-content-type-options"], "nosniff");
        assert_eq!(response.headers()["referrer-policy"], "no-referrer");
        let csp = response.headers()["content-security-policy"]
            .to_str()
            .unwrap();
        for directive in [
            "default-src 'none'",
            "script-src 'self'",
            "style-src 'self'",
            "frame-ancestors 'none'",
            "base-uri 'none'",
            "object-src 'none'",
        ] {
            assert!(csp.split("; ").any(|value| value == directive));
        }
        assert!(!csp.contains("unsafe-inline"));
        assert!(!csp.contains("unsafe-eval"));
        assert_eq!(
            response
                .into_body()
                .collect()
                .await
                .unwrap()
                .to_bytes()
                .as_ref(),
            include_bytes!("../web/index.html")
        );
    }
    for (path, mime, expected) in [
        (
            "/admin/app.js",
            "text/javascript; charset=utf-8",
            include_str!("../web/app.js"),
        ),
        (
            "/admin/styles.css",
            "text/css; charset=utf-8",
            include_str!("../web/styles.css"),
        ),
    ] {
        let response = app
            .clone()
            .oneshot(request("GET", path, String::new(), None))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()["content-type"], mime);
        assert_eq!(response.headers()["cache-control"], "no-store");
        assert_eq!(response.headers()["x-content-type-options"], "nosniff");
        assert_eq!(
            response
                .into_body()
                .collect()
                .await
                .unwrap()
                .to_bytes()
                .as_ref(),
            expected.as_bytes()
        );
    }
    for path in ["/admin/missing", "/admin/config.toml", "/admin/app.js/more"] {
        assert_eq!(
            app.clone()
                .oneshot(request("GET", path, String::new(), None))
                .await
                .unwrap()
                .status(),
            StatusCode::NOT_FOUND
        );
    }
    for path in ["/v1/status", "/v1/publications"] {
        assert_eq!(
            app.clone()
                .oneshot(request("GET", path, String::new(), None))
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
    }
}

#[tokio::test]
async fn preview_validates_normalizes_without_writes_and_sanitizes_body_errors() {
    let state = AppState::new(Store::open(":memory:").unwrap(), config(), Some(TOKEN));
    let app = router(state.clone());
    let mut draft: supplier_hub::model::PublicationDraft =
        serde_json::from_str(include_str!("../examples/supplier.json")).unwrap();
    draft.records.push(supplier_hub::model::RecordSnapshot {
        entity_type: "contact".into(), entity_id: uuid::Uuid::new_v4(), source_version: 1,
        data: serde_json::from_value(serde_json::json!({"supplier_id":draft.root.entity_id, "name":"Contact", "phone":"123"})).unwrap(),
    });
    let body = serde_json::to_string(&draft).unwrap();
    for token in [None, Some("incorrect")] {
        assert_eq!(
            app.clone()
                .oneshot(request(
                    "POST",
                    "/v1/publications/preview",
                    body.clone(),
                    token
                ))
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
    }
    for _ in 0..2 {
        let response = app
            .clone()
            .oneshot(request(
                "POST",
                "/v1/publications/preview",
                body.clone(),
                Some(TOKEN),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let value = response_json(response).await;
        assert_eq!(value["title"], draft.title());
        assert_eq!(value["record_count"], 2);
        draft.normalize();
        assert_eq!(value["draft"], serde_json::to_value(&draft).unwrap());
    }
    let mut invalid = draft.clone();
    invalid.records.retain(|r| r.entity_type != "contact");
    invalid.records[0].data.insert(
        "merged_into".into(),
        serde_json::json!(uuid::Uuid::new_v4()),
    );
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/v1/publications/preview",
            serde_json::to_string(&invalid).unwrap(),
            Some(TOKEN),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(
        response_json(response).await["error"],
        "invalid_publication"
    );
    for (body, expected_status) in [
        ("{private-secret".into(), StatusCode::BAD_REQUEST),
        (" ".repeat(1024 * 1024 + 1), StatusCode::PAYLOAD_TOO_LARGE),
    ] {
        let response = app
            .clone()
            .oneshot(request(
                "POST",
                "/v1/publications/preview",
                body,
                Some(TOKEN),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), expected_status);
        assert_eq!(
            response_json(response).await,
            serde_json::json!({"error":"invalid_publication_body"})
        );
    }
    let status = state.database(|db| db.status()).await.unwrap();
    assert_eq!(status.publication_count, 0);
    assert_eq!(status.revision_count, 0);
    assert_eq!(status.received_packages, 0);
    assert_eq!(status.exported_versions, 0);
    assert!(status.tasks.is_empty());
    // Preview includes configured origin validation, even without a database call.
    let mut invalid_config = config();
    invalid_config.center_id = uuid::Uuid::nil();
    let invalid_app = router(AppState::new(
        Store::open(":memory:").unwrap(),
        invalid_config,
        None,
    ));
    let response = invalid_app
        .oneshot(request("POST", "/v1/publications/preview", body, None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
}

#[tokio::test]
async fn safe_status_and_withdrawn_search_option() {
    let mut settings = config();
    settings.database = "/private/secret/database.db".into();
    settings.sync.directory = "/private/secret/sync".into();
    settings.sync.interval_seconds = 17;
    settings.sync.resend_seconds = 123;
    settings.sync.max_files_per_tick = 7;
    settings.sync.trusted_origin = Some(uuid::Uuid::new_v4());
    let trusted = settings.sync.trusted_origin;
    let state = AppState::new(Store::open(":memory:").unwrap(), settings, Some(TOKEN));
    let app = router(state.clone());
    let response = app
        .clone()
        .oneshot(request("GET", "/v1/status", String::new(), Some(TOKEN)))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let value = response_json(response).await;
    assert_eq!(value["sync_interval_seconds"], 17);
    assert_eq!(value["resend_seconds"], 123);
    assert_eq!(value["max_files_per_tick"], 7);
    assert_eq!(value["trusted_origin"], serde_json::json!(trusted));
    assert_eq!(value["authentication_required"], true);
    assert!(!value.to_string().contains("/private/secret"));
    assert!(!value.to_string().contains(TOKEN));
    assert!(value.get("token_hash").is_none());
    let mut draft: supplier_hub::model::PublicationDraft =
        serde_json::from_str(include_str!("../examples/supplier.json")).unwrap();
    draft.withdrawn = true;
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/v1/publications",
            serde_json::to_string(&draft).unwrap(),
            Some(TOKEN),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    for (query, count) in [
        ("", 0),
        ("?include_withdrawn=false", 0),
        ("?include_withdrawn=true", 1),
    ] {
        let response = app
            .clone()
            .oneshot(request(
                "GET",
                &format!("/v1/publications{query}"),
                String::new(),
                Some(TOKEN),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response_json(response).await["items"]
                .as_array()
                .unwrap()
                .len(),
            count
        );
    }
    let local = router(AppState::new(
        Store::open(":memory:").unwrap(),
        config(),
        None,
    ));
    let response = local
        .oneshot(request("GET", "/v1/status", String::new(), None))
        .await
        .unwrap();
    assert_eq!(
        response_json(response).await["authentication_required"],
        false
    );
}

#[tokio::test]
async fn preview_checks_complete_publication_size_including_origin() {
    const LIMIT: usize = 1024 * 1024;
    let mut draft: supplier_hub::model::PublicationDraft =
        serde_json::from_str(include_str!("../examples/supplier.json")).unwrap();
    for _ in 0..240 {
        draft.records.push(supplier_hub::model::RecordSnapshot {
            entity_type: "contact".into(),
            entity_id: uuid::Uuid::new_v4(),
            source_version: 1,
            data: serde_json::from_value(serde_json::json!({
                "supplier_id":draft.root.entity_id, "name":"x".repeat(2000),
                "phone":"1".repeat(2000), "notes":"x"
            }))
            .unwrap(),
        });
    }
    let mut remaining = LIMIT - 8 - serde_json::to_vec(&draft).unwrap().len();
    for record in draft.records.iter_mut().skip(1) {
        let add = remaining.min(1999);
        record
            .data
            .insert("notes".into(), serde_json::json!("x".repeat(add + 1)));
        remaining -= add;
    }
    assert_eq!(remaining, 0);
    draft.validate().unwrap();
    let body = serde_json::to_string(&draft).unwrap();
    assert_eq!(body.len(), LIMIT - 8);
    let state = AppState::new(Store::open(":memory:").unwrap(), config(), Some(TOKEN));
    let response = router(state.clone())
        .oneshot(request(
            "POST",
            "/v1/publications/preview",
            body,
            Some(TOKEN),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
    let value = response_json(response).await;
    assert_eq!(value["error"], "invalid_publication");
    assert_eq!(
        value["message"],
        "publication including origin exceeds 1 MiB"
    );
    assert_eq!(
        state
            .database(|db| db.status())
            .await
            .unwrap()
            .revision_count,
        0
    );
}

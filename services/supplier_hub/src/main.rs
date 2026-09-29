use std::{path::Path, sync::Arc, time::Duration};

use anyhow::{Context, bail};
use supplier_hub::{
    api::{AppState, router},
    config::{Config, Secrets},
    exchange,
    store::Store,
};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "supplier_hub=info".into()),
        )
        .init();
    let args: Vec<_> = std::env::args().collect();
    if args.len() < 3 || !matches!(args[1].as_str(), "serve" | "tick" | "backup") {
        bail!(
            "usage: supplier-hub <serve|tick> <config.toml> OR supplier-hub backup <config.toml> <new-backup.sqlite>"
        );
    }
    if (args[1] == "backup" && args.len() != 4) || (args[1] != "backup" && args.len() != 3) {
        bail!("unexpected command arguments");
    }
    let config = Config::load(Path::new(&args[2]))?;
    let secrets = if args[1] == "backup" {
        config.validate_storage()?;
        if !config.database.is_file() {
            bail!("backup source database does not exist");
        }
        Secrets {
            api_token: None,
            sync_key: None,
        }
    } else {
        let secrets = Secrets::from_env()?;
        config.validate(&secrets)?;
        secrets
    };
    if let Some(parent) = config
        .database
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
    {
        std::fs::create_dir_all(parent)?;
    }
    let mut store = Store::open(&config.database)?;
    // A center identity must not silently change while retaining its publication history.
    if let Some(id) = store.get_task_status("center_id")? {
        if id != config.center_id.to_string() {
            bail!("database center_id differs from configuration");
        }
    } else {
        store.set_task_status("center_id", &config.center_id.to_string())?;
    }
    if args[1] == "backup" {
        store.backup(Path::new(&args[3]))?;
        println!("backup completed");
        return Ok(());
    }
    if args[1] == "tick" {
        if !config.sync.enabled {
            println!("{{\"sync_enabled\":false}}");
            return Ok(());
        }
        let key = secrets.sync_key.as_deref().context("missing sync key")?;
        let report =
            exchange::run_once(&mut store, config.center_id, &config.exchange_config(), key)?;
        println!("{}", serde_json::to_string(&report)?);
        if report.failed != 0 {
            bail!("directory exchange contains failed items; inspect report");
        }
        return Ok(());
    }
    let address = config.bind;
    let state = AppState::new(store, config, secrets.api_token.as_deref());
    let listener = tokio::net::TcpListener::bind(address).await?;
    let (stop_tx, mut stop_rx) = tokio::sync::watch::channel(false);
    let task_state = state.clone();
    let sync_key = secrets.sync_key.map(Arc::new);
    let exchange_task = tokio::spawn(async move {
        if !task_state.config.sync.enabled {
            return;
        }
        let Some(key) = sync_key else {
            return;
        };
        let mut interval =
            tokio::time::interval(Duration::from_secs(task_state.config.sync.interval_seconds));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tokio::select! {
                biased;
                _ = stop_rx.changed() => break,
                _ = interval.tick() => {
                    let config = task_state.config.exchange_config();
                    let origin = task_state.config.center_id;
                    let key = Arc::clone(&key);
                    let result = task_state.database(move |db| exchange::run_once(db,origin,&config,&key)).await;
                    if let Err(error) = result {
                        tracing::error!(error = %error,"directory exchange failed");
                        let message = error.to_string().chars().take(300).collect::<String>();
                        if let Err(error) = task_state.database(move |db| db.set_task_status("directory_exchange",&message)).await {
                            tracing::error!(error = %error,"could not persist exchange failure");
                        }
                    }
                }
            }
        }
    });
    tracing::info!(address = %listener.local_addr()?,"supplier hub listening");
    let result = axum::serve(listener, router(state))
        .with_graceful_shutdown(shutdown_signal())
        .await;
    let _receivers = stop_tx.send(true);
    exchange_task.await.context("directory task failed")?;
    result?;
    Ok(())
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut terminate) => {
                tokio::select! { _ = tokio::signal::ctrl_c() => {}, _ = terminate.recv() => {} }
            }
            Err(error) => {
                tracing::error!(error = %error,"could not listen for termination");
                let _signal = tokio::signal::ctrl_c().await;
            }
        }
    }
    #[cfg(not(unix))]
    {
        let _signal = tokio::signal::ctrl_c().await;
    }
}

use context_manager::{discovery, lifecycle, summarization};

use atomos_db::AtomosDb;
use std::env;

#[tokio::main]
async fn main() -> surrealdb::Result<()> {
    println!("Starting Atom OS Context Manager...");

    // Default connection variables using ENV if available
    let surreal_url = env::var("SURREAL_URL").unwrap_or_else(|_| "ws://localhost:8000".to_string());
    let surreal_user = env::var("SURREAL_USER").unwrap_or_else(|_| "root".to_string());
    let surreal_pass = env::var("SURREAL_PASS").unwrap_or_else(|_| "root".to_string());
    let surreal_ns = env::var("SURREAL_NS").unwrap_or_else(|_| "atomos".to_string());
    // The Sync Manager operates on filesystem, the context properties are isolated to 'contexts' or 'core'
    let surreal_db = env::var("SURREAL_DB").unwrap_or_else(|_| "atomos".to_string());

    println!("Connecting to SurrealDB at {} ...", surreal_url);
    
    let db = AtomosDb::connect(&surreal_url, &surreal_user, &surreal_pass, &surreal_ns, &surreal_db).await?;
    
    println!("Database connected successfully.");

    // The background loops share the same DB pooling client
    let discovery_db = db.clone();
    let lifecycle_db = db.clone();
    let summary_db = db.clone();
    
    // 1. Spawn Context Discovery polling every 5 minutes (300s)
    tokio::spawn(async move {
        discovery::run_project_discovery_loop(discovery_db, 300).await;
    });

    // 2. Spawn Context Lifecycle/Activity Evaluation polling every hour (3600s)
    tokio::spawn(async move {
        lifecycle::run_project_lifecycle_loop(lifecycle_db, 3600).await;
    });

    // 3. Spawn Context Summarization Pipeline polling every hour (3600s)
    tokio::spawn(async move {
        summarization::run_summarization_loop(summary_db, 3600).await;
    });

    println!("Background workers dispatched. Press Ctrl+C to exit.");
    
    // Hold the process main thread alive until term signal
    tokio::signal::ctrl_c().await.expect("Failed to listen for event");
    println!("Shutting down Context Manager...");
    
    Ok(())
}

use atomos_db::models::ProjectContext;
use atomos_db::AtomosDb;
use surrealdb::sql::Datetime;
use std::time::Duration;

/// Main background loop for Project Context Discovery
pub async fn run_project_discovery_loop(db: AtomosDb, interval_seconds: u64) {
    let mut interval = tokio::time::interval(Duration::from_secs(interval_seconds));

    loop {
        interval.tick().await;
        println!("Running Project Context Discovery...");

        if let Err(e) = discover_projects(&db).await {
            eprintln!("Error during project discovery: {}", e);
        }
    }
}

/// Polls the document table for known project roots (Cargo.toml, package.json etc.)
/// and upserts them into project_context
async fn discover_projects(db: &AtomosDb) -> surrealdb::Result<()> {
    // We query the documents table for explicit project definition files.
    // In a real optimized system we would use the Vector / Full-text indexes.
    let root_query = r#"
        SELECT path FROM document 
        WHERE path ENDSWITH 'Cargo.toml' 
           OR path ENDSWITH 'package.json' 
           OR path ENDSWITH 'pyproject.toml'
           OR path ENDSWITH '.git/config';
    "#;

    let mut result = db.db.query(root_query).await?;
    
    // In SurrealDB, querying for just `path` returns objects like `{"path": "..."}`
    #[derive(serde::Deserialize, Debug)]
    struct DocPath {
        path: String,
    }

    let docs: Vec<DocPath> = result.take(0)?;
    
    for doc in docs {
        let root_path = extract_project_root(&doc.path);
        let name = root_path.split('/').last().unwrap_or("Unknown Project").to_string();
        
        let mut classification = "personal".to_string();
        
        // Before applying heuristics, check if there is a user override
        let override_query = format!("SELECT classification FROM project_classification_override WHERE path = '{}' LIMIT 1", root_path);
        if let Ok(mut override_res) = db.db.query(override_query).await {
            #[derive(serde::Deserialize)]
            struct OverrideClass { classification: String }
            if let Ok(overrides) = override_res.take::<Vec<OverrideClass>>(0) {
                if let Some(over) = overrides.first() {
                    classification = over.classification.clone();
                }
            }
        }
        
        // If no override found and it's a git config, run heuristic
        if classification == "personal" && doc.path.ends_with(".git/config") {
            let doc_content_query = format!("SELECT content FROM document WHERE path = '{}' LIMIT 1", doc.path);
            if let Ok(mut c_res) = db.db.query(doc_content_query).await {
                #[derive(serde::Deserialize)]
                struct DocContent { content: String }
                
                if let Ok(c_docs) = c_res.take::<Vec<DocContent>>(0) {
                    if let Some(c) = c_docs.first() {
                        classification = classify_git_remote(&c.content).to_string();
                    }
                }
            }
        }
        
        // Calculate activity score (document modifications in the last 24h)
        let mut activity_score = 0.0;
        let activity_query = r#"
            SELECT count() AS count FROM document 
            WHERE path STARTSWITH $root 
            AND modified_at > time::now() - 1d
            GROUP ALL;
        "#;
        if let Ok(mut act_res) = db.db.query(activity_query).bind(("root", root_path.clone())).await {
            #[derive(serde::Deserialize)]
            struct ActivityCount { count: i64 }
            if let Ok(counts) = act_res.take::<Vec<ActivityCount>>(0) {
                if let Some(ac) = counts.first() {
                    activity_score = (ac.count as f32) * 1.5; // Basic multiplier
                }
            }
        }
        
        let ctx = ProjectContext {
            id: None,
            name,
            path: root_path.clone(),
            status: "active".to_string(),
            created_at: Some(Datetime::default()),
            last_active: Some(Datetime::default()),
            summary: Some("Auto-discovered project context".to_string()),
            classification: Some(classification.to_string()),
            activity_score: Some(activity_score),
        };

        match upsert_project_context(db, &root_path, ctx).await {
            Ok(_) => println!("Successfully discovered/updated context: {}", root_path),
            Err(e) => eprintln!("Failed to track context {}: {}", root_path, e),
        }
    }

    Ok(())
}

/// Helper to upsert seamlessly avoiding duplicate keys
async fn upsert_project_context(db: &AtomosDb, path: &str, ctx: ProjectContext) -> surrealdb::Result<()> {
    // Use an ID friendly slug mapped to the root directory
    let safe_id = path.replace('/', "_").replace('.', "_");
    
    // Determine if it already exists
    let exists_query = format!("SELECT * FROM project_context:⟨{}⟩", safe_id);
    let mut res = db.db.query(exists_query).await?;
    let existing: Option<ProjectContext> = res.take(0)?;
    
    if existing.is_none() {
        let create_query = format!("CREATE project_context:⟨{}⟩ SET name = $name, path = $path, status = $status, summary = $summary, classification = $classification, activity_score = $activity_score", safe_id);
        db.db.query(create_query)
            .bind(("name", ctx.name))
            .bind(("path", ctx.path))
            .bind(("status", ctx.status))
            .bind(("summary", ctx.summary))
            .bind(("classification", ctx.classification))
            .bind(("activity_score", ctx.activity_score))
            .await?;
    } else {
        let update_query = format!("UPDATE project_context:⟨{}⟩ SET activity_score = $activity_score", safe_id);
        db.db.query(update_query).bind(("activity_score", ctx.activity_score)).await?;
    }
    
    Ok(())
}

/// Allows the user to manually correct a project's classification, improving the heuristics loop
pub async fn submit_classification_feedback(db: &AtomosDb, root_path: &str, classification: &str) -> surrealdb::Result<()> {
    let safe_id = root_path.replace('/', "_").replace('.', "_");
    let query = format!("UPSERT project_classification_override:⟨{}⟩ SET path = $path, classification = $classification", safe_id);
    db.db.query(query)
        .bind(("path", root_path.to_string()))
        .bind(("classification", classification.to_string()))
        .await?;
    Ok(())
}

// ---------------------------------------------------------
// Heuristics Engine 
// ---------------------------------------------------------

/// Strips the filename from the end, yielding the project's root folder path
pub fn extract_project_root(filepath: &str) -> String {
    let parts: Vec<&str> = filepath.split('/').collect();
    if parts.is_empty() {
        return filepath.to_string();
    }
    
    // Handle `.git/config` specially since it is two layers deep from root
    if filepath.ends_with(".git/config") {
        if parts.len() >= 3 {
             return parts[0..parts.len() - 2].join("/");
        }
    } else if parts.len() >= 2 {
         return parts[0..parts.len() - 1].join("/");
    }
    
    filepath.to_string()
}

/// Classifies a git remote string config as 'work' or 'personal'
pub fn classify_git_remote(git_config: &str) -> &'static str {
    // Dummy heuristic: if it contains an enterprise domain or "corp", "org"
    let lower = git_config.to_lowercase();
    if lower.contains("enterprise") || lower.contains("corp") || lower.contains("work") {
        return "work";
    }
    "personal"
}

// ---------------------------------------------------------
// Unit Tests
// ---------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_project_root() {
        assert_eq!(extract_project_root("/Users/bob/Project/Cargo.toml"), "/Users/bob/Project");
        assert_eq!(extract_project_root("/Users/bob/NodeApp/package.json"), "/Users/bob/NodeApp");
        assert_eq!(extract_project_root("/var/www/site/.git/config"), "/var/www/site");
        assert_eq!(extract_project_root("Cargo.toml"), "Cargo.toml"); // Edge case fallback
    }

    #[test]
    fn test_project_classification_work() {
        let mocked_work_remote = "[remote \"origin\"]\nurl = git@github.enterprise.corp:org/repo.git";
        assert_eq!(classify_git_remote(mocked_work_remote), "work");
    }

    #[test]
    fn test_project_classification_personal() {
        let mocked_personal_remote = "[remote \"origin\"]\nurl = git@github.com:user/repo.git";
        assert_eq!(classify_git_remote(mocked_personal_remote), "personal");
    }

    #[test]
    fn test_user_feedback_updates_classifier_weights() {
        // Placeholder for user feedback loop test
        // This will be implemented when the RLHF/feedback system is built
        assert!(true, "User feedback loop test placeholder");
    }
}

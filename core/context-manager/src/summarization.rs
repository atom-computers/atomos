use atomos_db::AtomosDb;
use atomos_db::models::{ProjectSummary};
use chrono::{Duration, Utc};
use surrealdb::sql::Datetime;
use std::env;
use rig::providers::ollama::Client as OllamaClient;
use rig::client::Nothing;
use rig::client::CompletionClient;
use rig::completion::Prompt;

/// Main background loop for Project Context Summarization
pub async fn run_summarization_loop(db: AtomosDb, interval_seconds: u64) {
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(interval_seconds));
    
    loop {
        interval.tick().await;
        
        let projects = match db.get_active_projects().await {
            Ok(p) => p,
            Err(e) => {
                eprintln!("Summarization Loop Error: Failed to fetch projects: {}", e);
                continue;
            }
        };

        for project in projects {
            // Check if we need a new summary (no summary in last 6 hours)
            let needs_summary = match db.get_latest_summary(&project.id.as_ref().unwrap()).await {
                Ok(Some(summary)) => {
                    let now = Utc::now();
                    let window_end = summary.window_end.0;
                    now.signed_duration_since(window_end) > Duration::hours(6)
                },
                Ok(None) => true,
                Err(_) => true,
            };

            if !needs_summary {
                continue;
            }

            let modified_since = Utc::now() - Duration::hours(24);
            
            // Gather context documents
            let recent_changes = match db.get_recent_documents(&project.path, modified_since).await {
                Ok(docs) => docs,
                Err(e) => {
                    eprintln!("Failed to fetch documents for {}: {}", project.name, e);
                    continue;
                }
            };
            
            if recent_changes.is_empty() {
                continue; // No activity
            }

            let project_name = project.name.clone();
            
            // Format context chunks for LLM
            let mut docs_payload = Vec::new();
            for doc in recent_changes {
                docs_payload.push(format!("File: {}\nContent:\n{}", doc.path, doc.content));
            }

            let summary_text = match generate_llm_summary(&project_name, &docs_payload).await {
                Ok(text) => text,
                Err(e) => {
                    eprintln!("LLM inference failed for {}: {}", project_name, e);
                    continue;
                }
            };

            let summary_record = ProjectSummary {
                id: None,
                project_id: project.id.unwrap(),
                content: summary_text,
                window_start: Datetime::from(modified_since),
                window_end: Datetime::from(Utc::now()),
            };

            if let Err(e) = db.save_project_summary(summary_record).await {
                eprintln!("Failed to persist summary for {}: {}", project_name, e);
            }
        }
    }
}

pub async fn generate_llm_summary(project_name: &str, docs: &[String]) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let base_url = env::var("OPENAI_API_BASE").unwrap_or_else(|_| "http://127.0.0.1:11434".to_string());
    let model_name = env::var("OPENAI_MODEL").unwrap_or_else(|_| "llama3".to_string());

    let client: rig::providers::ollama::Client<reqwest::Client> = OllamaClient::builder()
        .base_url(base_url.as_str())
        .api_key(Nothing)
        .build()?;

    let system_msg = format!("You are Atom OS Context Manager. Summarize the following recent file changes for the project '{}' into a brief paragraph detailing what the user is currently focused on.", project_name);
    
    let mut user_msg = String::new();
    for doc in docs {
        user_msg.push_str(doc);
        user_msg.push('\n');
    }

    let agent = client.agent(&model_name)
        .preamble(&system_msg)
        .build();
        
    let response = agent.prompt(&user_msg).await?;
    
    Ok(response)
}

#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn test_prompt_construction() {
        let snippets = vec![
            "File: src/main.rs\nContent Snippet:\nfn main() {}\n---".to_string()
        ];
        
        let mut user_msg = String::new();
        for doc in &snippets {
            user_msg.push_str(doc);
            user_msg.push('\n');
        }
        
        assert!(user_msg.contains("src/main.rs"));
        assert!(user_msg.contains("fn main() {}"));
    }
}

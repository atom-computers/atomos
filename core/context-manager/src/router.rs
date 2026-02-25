use atomos_db::AtomosDb;
use atomos_db::models::ProjectContext;
use rig::providers::ollama::Client as OllamaClient;
use rig::client::Nothing;
use rig::client::CompletionClient;
use rig::completion::Prompt;
use std::env;

/// Routes a user query to the most relevant active `ProjectContext`.
/// Returns `None` if the query is general and doesn't belong to any specific active project.
pub async fn route_intent(db: &AtomosDb, query: &str) -> Result<Option<ProjectContext>, Box<dyn std::error::Error + Send + Sync>> {
    let contexts = db.get_active_projects().await?;
    
    if contexts.is_empty() {
        return Ok(None);
    }

    let system_msg = build_routing_system_prompt(&contexts);

    let base_url = env::var("OPENAI_API_BASE").unwrap_or_else(|_| "http://127.0.0.1:11434".to_string());
    let model_name = env::var("OPENAI_MODEL").unwrap_or_else(|_| "llama3".to_string());

    let client: rig::providers::ollama::Client<reqwest::Client> = OllamaClient::builder()
        .base_url(base_url.as_str())
        .api_key(Nothing)
        .build()?;

    let agent = client.agent(&model_name)
        .preamble(&system_msg)
        // Set temperature to 0 for deterministic routing choices
        // (Assuming rig's `agent` builder eventually supports this, but for now prompt is strict)
        .build();

    let response = agent.prompt(query).await?;
    let response_trimmed = response.trim();

    if response_trimmed.to_uppercase() == "GENERAL" {
        return Ok(None);
    }

    // Attempt to match the returned ID to our active contexts
    for ctx in contexts {
        if let Some(id) = &ctx.id {
            if response_trimmed.contains(&id.to_raw()) || response_trimmed.contains(&id.to_string()) {
                return Ok(Some(ctx));
            }
        }
    }

    // Fallback if LLM halluciantes an ID
    Ok(None)
}

pub fn build_routing_system_prompt(contexts: &[ProjectContext]) -> String {
    let mut context_descriptions = String::new();
    for (i, ctx) in contexts.iter().enumerate() {
        let summary = ctx.summary.as_deref().unwrap_or("No summary available.");
        let id_str = if let Some(id) = &ctx.id {
            id.to_string()
        } else {
            "unknown".to_string()
        };
        context_descriptions.push_str(&format!("{}. [{}] {} - summary: {}\n", i, id_str, ctx.name, summary));
    }

    format!(
        "You are the Atom OS Context Router. Given the user's query and a list of active projects, determine which project the query refers to.\n\
        Active Projects:\n{}\n\
        If the query refers to one of these projects, reply ONLY with the exact ID string (e.g., 'project_context:xyz123'). \n\
        If the query is a general question or doesn't match any project, reply ONLY with the word 'GENERAL'. Do not include any other text.",
        context_descriptions
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use surrealdb::sql::{Thing, Id};

    #[test]
    fn test_build_routing_system_prompt() {
        let contexts = vec![
            ProjectContext {
                id: Some(Thing::from(("project_context", Id::from("123")))),
                name: "Test Project".to_string(),
                path: "/path/to/test".to_string(),
                status: "active".to_string(),
                created_at: None,
                last_active: None,
                summary: Some("A test summary".to_string()),
                classification: Some("work".to_string()),
                activity_score: None,
            }
        ];
        
        let prompt = build_routing_system_prompt(&contexts);
        assert!(prompt.contains("Test Project"));
        assert!(prompt.contains("A test summary"));
        assert!(prompt.contains("123"));
    }
}

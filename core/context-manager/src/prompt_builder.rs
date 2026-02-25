use atomos_db::AtomosDb;
use crate::cache::{check_semantic_cache, save_to_semantic_cache};
use crate::router::route_intent;
use crate::rag::hybrid_search;

pub struct BuiltPrompt {
    pub prompt: String,
    pub routed_project_id: Option<surrealdb::sql::Thing>,
    pub cache_hit: bool,
}

pub async fn build_prompt(db: &AtomosDb, user_query: &str) -> Result<BuiltPrompt, Box<dyn std::error::Error + Send + Sync>> {
    // 1. Check Semantic Cache
    if let Ok(Some(cache_entry)) = check_semantic_cache(db, user_query).await {
        return Ok(BuiltPrompt {
            prompt: cache_entry.cached_context.clone(),
            routed_project_id: cache_entry.routed_project_id,
            cache_hit: true,
        });
    }

    // 2. Route Intent (Find active project context or general)
    let routed_project = route_intent(db, user_query).await?;
    
    let mut final_prompt = String::from("You are Atom OS Assistant, a highly capable AI within the user's operating system.\n\n");
    let mut project_id = None;

    if let Some(project) = routed_project {
        project_id = project.id.clone();
        final_prompt.push_str(&format!("The user is currently focused on the project: {}\n", project.name));
        
        // 3. Fetch Project Summary
        let mut summary_text = None;
        if let Some(id) = &project.id {
            if let Ok(Some(summary)) = db.get_latest_summary(id).await {
                summary_text = Some(summary.content);
            }
        }

        // 4. Retrieve RAG chunks
        let docs = if let Ok(docs) = hybrid_search(db, &project.path, user_query, 5).await {
            docs
        } else {
            vec![]
        };

        final_prompt = format_prompt(Some(&project.name), summary_text.as_deref(), &docs, user_query);
    } else {
        final_prompt = format_prompt(None, None, &[], user_query);
    }

    // Save generated context to Semantic Cache 
    let _ = save_to_semantic_cache(db, user_query, &final_prompt, project_id.clone()).await;

    Ok(BuiltPrompt {
        prompt: final_prompt,
        routed_project_id: project_id,
        cache_hit: false,
    })
}

pub fn format_prompt(
    project_name: Option<&str>,
    project_summary: Option<&str>,
    docs: &[crate::rag::DocumentContext],
    user_query: &str,
) -> String {
    let mut final_prompt = String::from("You are Atom OS Assistant, a highly capable AI within the user's operating system.\n\n");
    if let Some(name) = project_name {
        final_prompt.push_str(&format!("The user is currently focused on the project: {}\n", name));
        if let Some(summary) = project_summary {
            final_prompt.push_str(&format!("Project Summary:\n{}\n\n", summary));
        }
        final_prompt.push_str("Relevant Context:\n");
        if docs.is_empty() {
            final_prompt.push_str("No specific file context found.\n");
        } else {
            for doc in docs {
                final_prompt.push_str(&format!("File: {}\nContent:\n{}\n\n", doc.path, doc.content));
            }
        }
    } else {
        final_prompt.push_str("The user's query is general and not scoped to a specific active project.\n\n");
    }
    final_prompt.push_str("User Query:\n");
    final_prompt.push_str(user_query);
    final_prompt
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rag::DocumentContext;

    #[test]
    fn test_pre_prompt_builder_assembles_correct_prompt_structure() {
        let docs = vec![
            DocumentContext {
                id: None,
                path: "/path/code.rs".to_string(),
                content: "fn main() {}".to_string(),
                modified_at: None,
            }
        ];
        
        let prompt = format_prompt(Some("Atom OS"), Some("Operating System"), &docs, "How does this work?");
        
        assert!(prompt.contains("The user is currently focused on the project: Atom OS"));
        assert!(prompt.contains("Project Summary:\nOperating System"));
        assert!(prompt.contains("File: /path/code.rs"));
        assert!(prompt.contains("fn main() {}"));
        assert!(prompt.contains("User Query:\nHow does this work?"));
    }

    #[test]
    fn test_pre_prompt_builder_general() {
        let prompt = format_prompt(None, None, &[], "What is the time?");
        assert!(prompt.contains("general and not scoped"));
        assert!(prompt.contains("What is the time?"));
    }
}

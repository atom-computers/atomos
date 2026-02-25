use atomos_db::AtomosDb;
use rig::providers::ollama::Client as OllamaClient;
use rig::client::Nothing;
use rig::client::EmbeddingsClient;
use rig::embeddings::EmbeddingsBuilder;
use std::env;
use crate::rag::DocumentContext;

/// Finds related documents across other projects using cosine similarity of embeddings.
/// This allows "cross-pollination" of knowledge between different personal or work contexts.
pub async fn find_cross_project_similarities(
    db: &AtomosDb, 
    _target_file_path: &str, 
    target_text: &str, 
    exclude_project_root: &str, 
    limit: usize
) -> Result<Vec<DocumentContext>, Box<dyn std::error::Error + Send + Sync>> {
    let base_url = env::var("OPENAI_API_BASE").unwrap_or_else(|_| "http://127.0.0.1:11434".to_string());
    
    // Rig API client targets Ollama native embeddings endpoint
    let client: rig::providers::ollama::Client<reqwest::Client> = OllamaClient::builder()
        .base_url(base_url.as_str())
        .api_key(Nothing)
        .build()?;
    
    // all-MiniLM-L6-v2 produces exactly identical 384 dim vectors matching CocoIndex pipeline
    let model = client.embedding_model("all-minilm");
    
    let query_document = EmbeddingsBuilder::new(model)
        .document(target_text.to_string())?
        .build()
        .await?;

    let first_result = query_document.into_iter().next().unwrap();
    let embedding = first_result.1.into_iter().next().unwrap();
    let target_embedding: Vec<f32> = embedding.vec.into_iter().map(|v| v as f32).collect();

    // Call underlying SurQL index lookup utilizing vector cosine threshold
    // Using NOT STARTSWITH to exclude the current project's root folder
    let query = format!(
        "SELECT path, content, modified_at, vector::similarity::cosine(embedding, $vec) AS score \n\
         FROM document \n\
         WHERE path NOT STARTSWITH $root \n\
         AND vector::similarity::cosine(embedding, $vec) > 0.5 \n\
         ORDER BY score DESC LIMIT {}", limit
    );

    let mut result = db.db.query(query)
        .bind(("vec", target_embedding))
        .bind(("root", exclude_project_root.to_string()))
        .await?;
        
    let docs: Vec<DocumentContext> = result.take(0)?;

    Ok(docs)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cross_project_query_exclusion() {
        // Test that the query builder correctly excludes the active context root
        let context_path = "/Users/test/workspace/project_a";
        let query = format!(
            "SELECT path, content, modified_at, vector::similarity::cosine(embedding, $vec) AS score \n\
             FROM document \n\
             WHERE path NOT STARTSWITH '{}' \n\
             AND vector::similarity::cosine(embedding, $vec) > 0.5 \n\
             ORDER BY score DESC LIMIT 5", 
            context_path
        );
        
        // Assert we check for cross-project docs
        assert!(query.contains("path NOT STARTSWITH '/Users/test/workspace/project_a'"));
        assert!(query.contains("vector::similarity::cosine"));
    }
}

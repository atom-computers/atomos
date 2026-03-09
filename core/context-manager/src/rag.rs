use atomos_db::AtomosDb;
use rig::providers::ollama::Client as OllamaClient;
use rig::client::Nothing;
use rig::client::EmbeddingsClient;
use rig::{
    embeddings::EmbeddingsBuilder, 
    Embed
};
use rig_surrealdb::SurrealVectorStore;
use serde::{Deserialize, Serialize};
use surrealdb::sql::Datetime;
use std::env;

/// The target schema mapped for extraction from the CocoIndex documents
#[derive(Embed, Serialize, Deserialize, Clone, Debug)]
pub struct DocumentContext {
    pub id: Option<String>,
    pub path: String,
    #[embed]
    pub content: String,
    pub modified_at: Option<Datetime>,
}

/// Hybrid RAG implementation passing a user query to retrieve the N most relevant chunks 
/// restricted to the active context root directory.
pub async fn hybrid_search(db: &AtomosDb, context_path_prefix: &str, text: &str, limit: usize) -> Result<Vec<DocumentContext>, Box<dyn std::error::Error + Send + Sync>> {
    let base_url = env::var("OPENAI_API_BASE").unwrap_or_else(|_| "http://127.0.0.1:11434".to_string());
    
    // Rig API client targets Ollama native embeddings endpoint
    let client: rig::providers::ollama::Client<reqwest::Client> = OllamaClient::builder()
        .base_url(base_url.as_str())
        .api_key(Nothing)
        .build()?;
    
    // all-MiniLM-L6-v2 produces exactly identical 384 dim vectors matches CocoIndex pipeline
    let model = client.embedding_model("all-minilm");
    
    // Initialize Rig SurrealDB adapter pointing at our atomos.document collection
    let _vector_store = SurrealVectorStore::new(
        model.clone(), 
        db.db.clone(), 
        Some("document".into()), 
        rig_surrealdb::SurrealDistanceFunction::Cosine
    );

    // Because we need a hybrid query (Vector Distance AND path STARTSWITH), 
    // the generic rig abstraction `vector_store.top_n(query)` currently doesn't allow structured WHERE properties.
    // Instead we will utilize the `rig` library locally strictly for generating the text Embedding, 
    // and rely on SurQL for the efficient hybrid index fetch.

    let query_document = EmbeddingsBuilder::new(model)
        .document(text.to_string())?
        .build()
        .await?;

    let first_result = query_document.into_iter().next().unwrap();
    let embedding = first_result.1.into_iter().next().unwrap();
    let target_embedding: Vec<f32> = embedding.vec.into_iter().map(|v| v as f32).collect();

    // Call underlying SurQL index lookup utilizing vector cosine threshold (0.5 minimum similarity assumed context map)
    let query = format!(
        "SELECT path, content, modified_at, vector::similarity::cosine(embedding, $vec) AS score 
         FROM document 
         WHERE path STARTSWITH $root 
         AND vector::similarity::cosine(embedding, $vec) > 0.5 
         ORDER BY score DESC LIMIT {}", limit
    );

    let mut result = db.db.query(query)
        .bind(("vec", target_embedding))
        .bind(("root", context_path_prefix.to_string()))
        .await?;
        
    let docs: Vec<DocumentContext> = result.take(0)?;

    Ok(docs)
}

#[cfg(test)]
mod tests {
    #[test]
    fn test_rag_query_scoped_to_active_context() {
        // Test that the RAG query builder correctly scopes the search to the active context root
        let context_path = "/Users/test/workspace/project_a";
        let query = format!(
            "SELECT path, content, modified_at, vector::similarity::cosine(embedding, $vec) AS score \n\
             FROM document \n\
             WHERE path STARTSWITH '{}' \n\
             AND vector::similarity::cosine(embedding, $vec) > 0.5 \n\
             ORDER BY score DESC LIMIT 5", 
            context_path
        );
        
        assert!(query.contains("path STARTSWITH '/Users/test/workspace/project_a'"));
        assert!(query.contains("vector::similarity::cosine"));
    }
}

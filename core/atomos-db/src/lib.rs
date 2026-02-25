pub mod models;

use surrealdb::engine::remote::ws::{Client, Ws};
use surrealdb::opt::auth::Root;
use surrealdb::Surreal;
use surrealdb::Result;
use models::*;

#[derive(Clone)]
pub struct AtomosDb {
    pub db: Surreal<Client>,
}

impl AtomosDb {
    pub async fn connect(url: &str, user: &str, pass: &str, ns: &str, db_name: &str) -> Result<Self> {
        let db = Surreal::new::<Ws>(url).await?;
        db.signin(Root {
            username: user,
            password: pass,
        }).await?;
        db.use_ns(ns).use_db(db_name).await?;
        Ok(Self { db })
    }

    /// Read all MCP servers from the database
    pub async fn get_mcp_servers(&self) -> Result<Vec<McpServer>> {
        let mut result = self.db.query("SELECT * FROM mcp_server").await?;
        let servers: Vec<McpServer> = result.take(0)?;
        Ok(servers)
    }

    /// Read active project contexts 
    pub async fn get_active_contexts(&self) -> Result<Vec<ProjectContext>> {
        let mut result = self.db.query(
            "SELECT * FROM project_context WHERE status = 'active'"
        ).await?;
        let contexts: Vec<ProjectContext> = result.take(0)?;
        Ok(contexts)
    }

    /// A basic CRUD helper to create a project context
    pub async fn create_project_context(&self, ctx: ProjectContext) -> Result<ProjectContext> {
        let mut result = self.db.query(
            "CREATE project_context SET name = $name, path = $path, status = $status, summary = $summary, classification = $classification"
        )
        .bind(("name", ctx.name))
        .bind(("path", ctx.path))
        .bind(("status", ctx.status))
        .bind(("summary", ctx.summary))
        .bind(("classification", ctx.classification))
        .await?;
        
        let created: Option<ProjectContext> = result.take(0)?;
        // Just return what we created (or an error if missing)
        Ok(created.expect("Failed to create context"))
    }

    /// Vector search query for documents. 
    /// Given a query embedding, return the top N matches with score above threshold.
    pub async fn search_documents_by_embedding(&self, embedding: Vec<f32>, limit: u32, threshold: f32) -> Result<Vec<surrealdb::sql::Value>> {
        let query = format!(
            "SELECT *, vector::similarity::cosine(embedding, $vec) AS score FROM document WHERE vector::similarity::cosine(embedding, $vec) > {} ORDER BY score DESC LIMIT {}",
            threshold, limit
        );
        let mut result = self.db.query(query).bind(("vec", embedding)).await?;
        let docs: Vec<surrealdb::sql::Value> = result.take(0)?;
        Ok(docs)
    }

    /// Subscribe to live query (SurrealDB LIVE SELECT)
    /// Returns a LiveStream which yields updates when records change.
    pub async fn subscribe_live_sync(&self, table: &str) -> Result<surrealdb::method::QueryStream<surrealdb::Notification<surrealdb::sql::Value>>> {
        let mut query_result = self.db.query(format!("LIVE SELECT * FROM {}", table)).await?;
        let stream = query_result.stream::<surrealdb::Notification<surrealdb::sql::Value>>(0)?;
        Ok(stream)
    }

    /// Read active project contexts
    pub async fn get_active_projects(&self) -> Result<Vec<ProjectContext>> {
        self.get_active_contexts().await
    }

    /// Read the latest summary for a specific project
    pub async fn get_latest_summary(&self, project_id: &surrealdb::sql::Thing) -> Result<Option<ProjectSummary>> {
        let mut result = self.db.query("SELECT * FROM project_summary WHERE project_id = $project_id ORDER BY window_end DESC LIMIT 1")
            .bind(("project_id", project_id.clone()))
            .await?;
        let summary: Option<ProjectSummary> = result.take(0)?;
        Ok(summary)
    }

    /// Read recently modified documents falling under a project's path
    pub async fn get_recent_documents(&self, prefix_path: &str, since: chrono::DateTime<chrono::Utc>) -> Result<Vec<DocumentContext>> {
        let mut result = self.db.query("SELECT * FROM document WHERE path STARTSWITH $path AND modified_at > $since")
            .bind(("path", prefix_path.to_string()))
            .bind(("since", surrealdb::sql::Datetime::from(since)))
            .await?;
        let docs: Vec<DocumentContext> = result.take(0)?;
        Ok(docs)
    }

    /// Save the LLM rolling context summary to the database 
    pub async fn save_project_summary(&self, summary: ProjectSummary) -> Result<ProjectSummary> {
        let mut result = self.db.query(
            "CREATE project_summary CONTENT $data"
        )
        .bind(("data", summary))
        .await?;
        
        let created: Option<ProjectSummary> = result.take(0)?;
        Ok(created.expect("Failed to create summary"))
    }

    /// Find a semantically similar cached query
    pub async fn find_cached_semantic_query(&self, target_embedding: Vec<f32>, threshold: f32) -> Result<Option<SemanticCache>> {
        let query = format!(
            "SELECT *, vector::similarity::cosine(embedding, $vec) AS score FROM semantic_cache WHERE vector::similarity::cosine(embedding, $vec) > {} ORDER BY score DESC LIMIT 1",
            threshold
        );
        let mut result = self.db.query(query).bind(("vec", target_embedding)).await?;
        let cache_hit: Option<SemanticCache> = result.take(0)?;
        Ok(cache_hit)
    }

    /// Save a semantic cache entry
    pub async fn save_semantic_cache(&self, cache: SemanticCache) -> Result<SemanticCache> {
        let mut result = self.db.query(
            "CREATE semantic_cache CONTENT $data"
        )
        .bind(("data", cache))
        .await?;
        
        let created: Option<SemanticCache> = result.take(0)?;
        Ok(created.expect("Failed to create semantic cache entry"))
    }

    /// Save workflow execution state
    pub async fn save_workflow_execution(&self, exec: WorkflowExecution) -> Result<WorkflowExecution> {
        // If an ID is provided, UPDATE it, else CREATE
        let query = if exec.id.is_some() {
            "UPDATE $id CONTENT $data"
        } else {
            "CREATE workflow_execution CONTENT $data"
        };
        
        let mut result = self.db.query(query)
            .bind(("id", exec.id.clone()))
            .bind(("data", exec))
            .await?;
            
        let saved: Option<WorkflowExecution> = result.take(0)?;
        Ok(saved.expect("Failed to save workflow execution"))
    }

    /// Retrieve a workflow execution by ID
    pub async fn get_workflow_execution(&self, id: &surrealdb::sql::Thing) -> Result<Option<WorkflowExecution>> {
        let mut result = self.db.query("SELECT * FROM $id")
            .bind(("id", id.clone()))
            .await?;
        let exec: Option<WorkflowExecution> = result.take(0)?;
        Ok(exec)
    }

    /// Save a workflow event
    pub async fn save_workflow_event(&self, event: WorkflowEvent) -> Result<WorkflowEvent> {
        let mut result = self.db.query(
            "CREATE workflow_event CONTENT $data"
        )
        .bind(("data", event))
        .await?;
        
        let created: Option<WorkflowEvent> = result.take(0)?;
        Ok(created.expect("Failed to create workflow event"))
    }
}

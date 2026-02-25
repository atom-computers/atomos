use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use surrealdb::sql::{Datetime, Thing, Value};

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct McpServer {
    pub id: Option<Thing>,
    pub name: String,
    pub url: String,
    pub status: String,
    pub supported_tools: Option<Vec<String>>,
    pub last_connected: Option<Datetime>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ChatThread {
    pub id: Option<Thing>,
    pub title: String,
    pub created_at: Option<Datetime>,
    pub updated_at: Option<Datetime>,
    pub context_id: Option<Thing>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ChatMessage {
    pub id: Option<Thing>,
    pub thread_id: Thing,
    pub role: String,
    pub content: String,
    pub meta: Option<BTreeMap<String, Value>>,
    pub timestamp: Option<Datetime>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Contact {
    pub id: Option<Thing>,
    pub name: String,
    pub aliases: Option<Vec<String>>,
    pub metadata: Option<BTreeMap<String, Value>>,
    pub relations: Option<Vec<Thing>>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ProjectContext {
    pub id: Option<Thing>,
    pub name: String,
    pub path: String,
    pub status: String,
    pub created_at: Option<Datetime>,
    pub last_active: Option<Datetime>,
    pub summary: Option<String>,
    pub classification: Option<String>,
    pub activity_score: Option<f32>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct WorkflowExecution {
    pub id: Option<Thing>,
    pub name: String,
    pub status: String,
    pub created_at: Option<Datetime>,
    pub updated_at: Option<Datetime>,
    pub state_data: Option<BTreeMap<String, Value>>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ProjectSummary {
    pub id: Option<Thing>,
    pub project_id: Thing,
    pub content: String,
    pub window_start: Datetime,
    pub window_end: Datetime,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct WorkflowEvent {
    pub id: Option<Thing>,
    pub execution_id: Thing,
    pub event_type: String,
    pub payload: Option<BTreeMap<String, Value>>,
    pub timestamp: Option<Datetime>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct DocumentContext {
    pub id: Option<Thing>,
    pub path: String,
    pub content: String,
    pub modified_at: Option<Datetime>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct SemanticCache {
    pub id: Option<Thing>,
    pub query: String,
    pub embedding: Vec<f32>,
    pub cached_context: String,
    pub routed_project_id: Option<Thing>,
    pub created_at: Option<Datetime>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_mcp_server_serialization() {
        let server = McpServer {
            id: None,
            name: "test-server".to_string(),
            url: "http://localhost:8080".to_string(),
            status: "connected".to_string(),
            supported_tools: Some(vec!["tool1".to_string(), "tool2".to_string()]),
            last_connected: None,
        };

        let serialized = serde_json::to_string(&server).unwrap();
        assert!(serialized.contains("test-server"));
        assert!(serialized.contains("tool1"));

        let deserialized: McpServer = serde_json::from_str(&serialized).unwrap();
        assert_eq!(deserialized.name, server.name);
        assert_eq!(deserialized.url, server.url);
    }
}

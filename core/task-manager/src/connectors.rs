use async_trait::async_trait;
use serde_json::Value;

#[async_trait]
pub trait Connector: Send + Sync {
    fn name(&self) -> String;
    async fn execute(&self, instruction: Value) -> Result<Value, String>;
}

pub struct GenerativeUiConnector {}

#[async_trait]
impl Connector for GenerativeUiConnector {
    fn name(&self) -> String {
        "generative_ui".to_string()
    }

    async fn execute(&self, instruction: Value) -> Result<Value, String> {
        Ok(serde_json::json!({
            "status": "rendered",
            "instruction": instruction
        }))
    }
}

pub struct TerminalConnector {}

#[async_trait]
impl Connector for TerminalConnector {
    fn name(&self) -> String {
        "terminal_sandbox".to_string()
    }

    async fn execute(&self, _instruction: Value) -> Result<Value, String> {
        Ok(serde_json::json!({
            "stdout": "mocked output",
            "stderr": ""
        }))
    }
}

pub struct BrowserConnector {}

#[async_trait]
impl Connector for BrowserConnector {
    fn name(&self) -> String {
        "headless_browser".to_string()
    }

    async fn execute(&self, instruction: Value) -> Result<Value, String> {
        Ok(serde_json::json!({
            "page_content": "mocked HTML",
            "url": instruction.get("url").and_then(|v| v.as_str()).unwrap_or("")
        }))
    }
}

pub struct DataConnector {}

#[async_trait]
impl Connector for DataConnector {
    fn name(&self) -> String {
        "api_retrieval".to_string()
    }

    async fn execute(&self, _instruction: Value) -> Result<Value, String> {
        Ok(serde_json::json!({
            "data": "mocked API response"
        }))
    }
}

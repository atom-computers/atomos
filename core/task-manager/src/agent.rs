use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::time::Duration;

#[async_trait]
pub trait Agent: Send + Sync {
    fn name(&self) -> String;
    
    async fn plan(&self, objective: &str) -> Result<Vec<String>, String>;
    
    async fn execute(&self, step: &str, context: &AgentContext) -> Result<serde_json::Value, String>;
    
    async fn report(&self, results: &[serde_json::Value]) -> Result<String, String>;
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentContext {
    pub execution_id: String,
    pub shared_memory: HashMap<String, String>,
}

#[derive(Default)]
pub struct Orchestrator {}

impl Orchestrator {
    pub fn new() -> Self {
        Self {}
    }

    pub async fn spawn_agent<A: Agent + 'static>(&self, agent: A, objective: String) -> Result<String, String> {
        let handle = tokio::spawn(async move {
            let plan = agent.plan(&objective).await?;
            let mut results = Vec::new();
            
            let context = AgentContext {
                execution_id: uuid::Uuid::new_v4().to_string(),
                shared_memory: HashMap::new(),
            };

            for step in plan {
                let mut attempts = 0;
                let mut step_result = Err("Init".to_string());
                while attempts < 3 {
                    match tokio::time::timeout(Duration::from_secs(30), agent.execute(&step, &context)).await {
                        Ok(Ok(res)) => {
                            step_result = Ok(res);
                            break;
                        }
                        Ok(Err(e)) => {
                            attempts += 1;
                            step_result = Err(e);
                        }
                        Err(_) => {
                            attempts += 1;
                            step_result = Err("Timeout".to_string());
                        }
                    }
                }
                
                results.push(step_result?);
            }
            
            agent.report(&results).await
        });

        handle.await.map_err(|e| e.to_string())?
    }
}

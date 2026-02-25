use atomos_db::AtomosDb;
use atomos_db::models::{WorkflowExecution, WorkflowEvent};
use chrono::Utc;
use serde_json::Value;
use surrealdb::sql::Thing;
use std::str::FromStr;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum WorkflowState {
    Pending,
    Running,
    Paused,
    Completed,
    Failed(String),
    Cancelled,
}

impl ToString for WorkflowState {
    fn to_string(&self) -> String {
        match self {
            WorkflowState::Pending => "Pending".to_string(),
            WorkflowState::Running => "Running".to_string(),
            WorkflowState::Paused => "Paused".to_string(),
            WorkflowState::Completed => "Completed".to_string(),
            WorkflowState::Failed(reason) => format!("Failed: {}", reason),
            WorkflowState::Cancelled => "Cancelled".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowStep {
    pub id: String,
    pub name: String,
    pub action: String,
    pub inputs: serde_json::Value,
    pub next_steps: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Workflow {
    pub id: String,
    pub name: String,
    pub steps: HashMap<String, WorkflowStep>,
    pub initial_step: String,
    pub state: WorkflowState,
    pub results: HashMap<String, serde_json::Value>,
    pub current_step: Option<String>,
}

impl Default for Workflow {
    fn default() -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            name: "default_workflow".to_string(),
            steps: HashMap::new(),
            initial_step: "".to_string(),
            state: WorkflowState::Pending,
            results: HashMap::new(),
            current_step: None,
        }
    }
}

impl Workflow {
    pub fn new(name: &str, initial_step: &str) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            name: name.to_string(),
            steps: HashMap::new(),
            initial_step: initial_step.to_string(),
            state: WorkflowState::Pending,
            results: HashMap::new(),
            current_step: Some(initial_step.to_string()),
        }
    }

    pub fn add_step(&mut self, step: WorkflowStep) {
        self.steps.insert(step.id.clone(), step);
    }

    pub fn transition_next(&mut self, next_step_id: &str) -> Result<(), String> {
        if !self.steps.contains_key(next_step_id) {
            return Err(format!("Step {} does not exist in workflow", next_step_id));
        }
        self.current_step = Some(next_step_id.to_string());
        Ok(())
    }
}

pub struct WorkflowEngine {
    db: Option<AtomosDb>,
}

impl WorkflowEngine {
    pub fn new(db: Option<AtomosDb>) -> Self {
        Self { db }
    }

    async fn persist(&self, workflow: &Workflow) -> Result<(), String> {
        if let Some(db) = &self.db {
            let state_str = serde_json::to_string(&workflow).map_err(|e| e.to_string())?;
            let state_data: BTreeMap<String, surrealdb::sql::Value> = serde_json::from_str(&state_str).map_err(|e| e.to_string())?;

            let id = Thing::from_str(&format!("workflow_execution:{}", workflow.id))
                .map_err(|_| "Invalid ID format".to_string())?;

            let exec = WorkflowExecution {
                id: Some(id),
                name: workflow.name.clone(),
                status: workflow.state.to_string(),
                created_at: Some(surrealdb::sql::Datetime::from(Utc::now())),
                updated_at: Some(surrealdb::sql::Datetime::from(Utc::now())),
                state_data: Some(state_data),
            };

            db.save_workflow_execution(exec).await.map_err(|e| format!("{:?}", e))?;
        }
        Ok(())
    }

    async fn record_event(&self, workflow_id: &str, event_type: &str, payload: Value) -> Result<(), String> {
        if let Some(db) = &self.db {
            let exec_id = Thing::from_str(&format!("workflow_execution:{}", workflow_id))
                .map_err(|_| "Invalid ID format".to_string())?;

            let payload_str = serde_json::to_string(&payload).map_err(|e| e.to_string())?;
            let payload_map: BTreeMap<String, surrealdb::sql::Value> = serde_json::from_str(&payload_str).unwrap_or_default();

            let event = WorkflowEvent {
                id: None,
                execution_id: exec_id,
                event_type: event_type.to_string(),
                payload: Some(payload_map),
                timestamp: Some(surrealdb::sql::Datetime::from(Utc::now())),
            };

            db.save_workflow_event(event).await.map_err(|e| format!("{:?}", e))?;
        }
        Ok(())
    }

    pub async fn execute(&mut self, workflow: &mut Workflow) -> Result<(), String> {
        workflow.state = WorkflowState::Running;
        self.persist(workflow).await?;
        
        while let Some(step_id) = &workflow.current_step.clone() {
            if let Some(step) = workflow.steps.get(step_id) {
                // Mock execution
                let output = serde_json::json!({ "status": "executed", "step": step_id });
                workflow.results.insert(step_id.clone(), output.clone());
                
                // Advanced logic would select the next step dynamically
                if let Some(next) = step.next_steps.first() {
                    workflow.current_step = Some(next.clone());
                } else {
                    workflow.current_step = None;
                }
                
                self.record_event(&workflow.id, &format!("step_completed: {}", step_id), output).await?;
                self.persist(workflow).await?;
            } else {
                workflow.state = WorkflowState::Failed(format!("Step {} not found", step_id));
                self.persist(workflow).await?;
                return Err(format!("Failed to find step {}", step_id));
            }
        }
        
        workflow.state = WorkflowState::Completed;
        self.persist(workflow).await?;
        Ok(())
    }

    pub async fn cancel(&mut self, workflow: &mut Workflow) {
        workflow.state = WorkflowState::Cancelled;
        let _ = self.persist(workflow).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_workflow_state_machine() {
        let mut workflow = Workflow::new("test_wf", "step1");
        workflow.add_step(WorkflowStep {
            id: "step1".to_string(),
            name: "First Step".to_string(),
            action: "mock_action_1".to_string(),
            inputs: serde_json::json!({}),
            next_steps: vec!["step2".to_string()],
        });
        workflow.add_step(WorkflowStep {
            id: "step2".to_string(),
            name: "Second Step".to_string(),
            action: "mock_action_2".to_string(),
            inputs: serde_json::json!({}),
            next_steps: vec![],
        });

        let mut engine = WorkflowEngine::new(None); // no db for tests
        let result = engine.execute(&mut workflow).await;
        
        assert!(result.is_ok());
        assert_eq!(workflow.state, WorkflowState::Completed);
        assert_eq!(workflow.results.len(), 2);
    }
}


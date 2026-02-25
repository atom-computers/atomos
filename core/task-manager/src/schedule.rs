use std::sync::Arc;
use tokio::sync::{broadcast, Mutex};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::BinaryHeap;
use std::cmp::Ordering;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Event {
    pub id: String,
    pub topic: String,
    pub payload: serde_json::Value,
    pub timestamp: DateTime<Utc>,
}

#[derive(Clone)]
pub struct EventBus {
    sender: broadcast::Sender<Event>,
}

impl Default for EventBus {
    fn default() -> Self {
        Self::new(100)
    }
}

impl EventBus {
    pub fn new(capacity: usize) -> Self {
        let (sender, _) = broadcast::channel(capacity);
        Self { sender }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.sender.subscribe()
    }

    pub fn publish(&self, event: Event) -> Result<usize, broadcast::error::SendError<Event>> {
        self.sender.send(event)
    }
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct ScheduledTask {
    pub execute_at: DateTime<Utc>,
    pub workflow_id: String,
    pub payload: serde_json::Value,
}

impl Ord for ScheduledTask {
    fn cmp(&self, other: &Self) -> Ordering {
        // Reverse ordering so earliest time is popped first from BinaryHeap
        other.execute_at.cmp(&self.execute_at)
    }
}

impl PartialOrd for ScheduledTask {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

#[derive(Clone)]
pub struct Scheduler {
    queue: Arc<Mutex<BinaryHeap<ScheduledTask>>>,
    event_bus: Arc<EventBus>,
}

impl Scheduler {
    pub fn new(event_bus: Arc<EventBus>) -> Self {
        Self {
            queue: Arc::new(Mutex::new(BinaryHeap::new())),
            event_bus,
        }
    }

    pub async fn schedule(&self, task: ScheduledTask) {
        let mut queue = self.queue.lock().await;
        queue.push(task);
    }

    pub async fn tick(&self) {
        let now = Utc::now();
        let mut queue = self.queue.lock().await;
        
        while let Some(task) = queue.peek() {
            if task.execute_at <= now {
                let task = queue.pop().unwrap();
                let event = Event {
                    id: uuid::Uuid::new_v4().to_string(),
                    topic: "workflow_trigger".to_string(),
                    payload: serde_json::json!({
                        "workflow_id": task.workflow_id,
                        "data": task.payload
                    }),
                    timestamp: Utc::now()
                };
                let _ = self.event_bus.publish(event);
            } else {
                break;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_event_bus() {
        let bus = EventBus::new(10);
        let mut rx = bus.subscribe();
        
        bus.publish(Event {
            id: "1".to_string(),
            topic: "test".to_string(),
            payload: serde_json::json!({}),
            timestamp: Utc::now(),
        }).unwrap();

        let event = rx.recv().await.unwrap();
        assert_eq!(event.topic, "test");
    }

    #[tokio::test]
    async fn test_scheduler() {
        let bus = Arc::new(EventBus::new(10));
        let mut rx = bus.subscribe();
        let scheduler = Scheduler::new(bus.clone());

        scheduler.schedule(ScheduledTask {
            execute_at: Utc::now() - chrono::Duration::try_seconds(1).unwrap(),
            workflow_id: "wf_1".to_string(),
            payload: serde_json::json!({}),
        }).await;

        scheduler.tick().await;

        let event = rx.recv().await.unwrap();
        assert_eq!(event.topic, "workflow_trigger");
    }
}

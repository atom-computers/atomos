use crate::agent::agent_service_client::AgentServiceClient;
use crate::agent::{
    AgentRequest, AgentResponse, ApprovalRequest, ChatMessage, HasSecretRequest, StoreSecretRequest,
};
use tonic::transport::Channel;

#[derive(Clone)]
pub struct BridgeClient {
    client: AgentServiceClient<Channel>,
}

impl BridgeClient {
    pub async fn connect(address: String) -> anyhow::Result<Self> {
        let client = AgentServiceClient::connect(address).await?;
        Ok(Self { client })
    }

    pub async fn stream_agent_turn(
        &mut self,
        prompt: String,
        model: String,
        images: Vec<String>,
        context: Option<Vec<u64>>,
        history: Vec<ChatMessage>,
        thread_id: String,
    ) -> anyhow::Result<tonic::Streaming<AgentResponse>> {
        let request = tonic::Request::new(AgentRequest {
            prompt,
            model,
            images,
            context: context.unwrap_or_default(),
            history,
            thread_id,
        });

        let response = self.client.stream_agent_turn(request).await?;
        Ok(response.into_inner())
    }

    /// Store a secret in the agent server's keyring.
    /// Returns true on success. The value is transmitted over the local
    /// gRPC socket and stored in gnome-keyring / encrypted-file fallback.
    pub async fn store_secret(
        &mut self,
        service: String,
        key: String,
        value: String,
    ) -> anyhow::Result<bool> {
        let request = tonic::Request::new(StoreSecretRequest {
            service,
            key,
            value,
        });
        let response = self.client.store_secret(request).await?;
        Ok(response.into_inner().success)
    }

    /// Check whether a secret is already stored in the agent server's keyring.
    pub async fn has_secret(&mut self, service: String, key: String) -> anyhow::Result<bool> {
        let request = tonic::Request::new(HasSecretRequest { service, key });
        let response = self.client.has_secret(request).await?;
        Ok(response.into_inner().exists)
    }

    /// Send a human-in-the-loop approval response for an approval prompt.
    /// Returns true if the server accepted the approval.
    pub async fn send_approval(
        &mut self,
        block_id: String,
        action_id: String,
    ) -> anyhow::Result<bool> {
        let request = tonic::Request::new(ApprovalRequest {
            block_id,
            action_id,
        });
        let response = self.client.send_approval(request).await?;
        Ok(response.into_inner().success)
    }
}

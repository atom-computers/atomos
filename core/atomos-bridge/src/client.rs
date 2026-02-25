use crate::agent::agent_service_client::AgentServiceClient;
use crate::agent::{AgentRequest, AgentResponse};
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
    ) -> anyhow::Result<tonic::Streaming<AgentResponse>> {
        let request = tonic::Request::new(AgentRequest {
            prompt,
            model,
            images,
            context: context.unwrap_or_default(),
        });

        let response = self.client.stream_agent_turn(request).await?;
        Ok(response.into_inner())
    }
}

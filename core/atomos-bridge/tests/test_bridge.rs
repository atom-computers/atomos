#[cfg(test)]
mod tests {
    use atomos_bridge::agent::{AgentRequest, AgentResponse};

    #[test]
    fn test_proto_serialization() {
        let request = AgentRequest {
            prompt: "Test prompt".to_string(),
            model: "llama3".to_string(),
            images: vec![],
            context: vec![1, 2, 3],
        };

        assert_eq!(request.prompt, "Test prompt");
        assert_eq!(request.model, "llama3");
        assert_eq!(request.context, vec![1, 2, 3]);

        let response = AgentResponse {
            content: "Test response".to_string(),
            done: true,
            tool_call: "".to_string(),
            status: "Done".to_string(),
        };

        assert_eq!(response.content, "Test response");
        assert_eq!(response.done, true);
        assert_eq!(response.status, "Done");
    }
}

#[cfg(test)]
mod tests {
    use atomos_bridge::client::BridgeClient;
    use tokio;

    #[tokio::test]
    async fn test_reconnection_failure() {
        // Test that connecting to an invalid port returns an error correctly
        let result = BridgeClient::connect("http://localhost:59999".to_string()).await;
        assert!(result.is_err(), "Client should fail to connect to invalid port");
    }
}

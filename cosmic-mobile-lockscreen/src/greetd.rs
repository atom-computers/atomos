use std::io::{Read, Write};
use std::os::unix::net::UnixStream;

const DEFAULT_SESSION_CMD: &str = "cosmic-session";
const DEFAULT_USERNAME: &str = "user";

fn sock_path() -> Result<String, String> {
    std::env::var("GREETD_SOCK").map_err(|_| "GREETD_SOCK not set".to_string())
}

fn send(stream: &mut UnixStream, msg: &serde_json::Value) -> Result<(), String> {
    let payload = serde_json::to_vec(msg).map_err(|e| format!("json encode: {e}"))?;
    let len = (payload.len() as u32).to_le_bytes();
    stream.write_all(&len).map_err(|e| format!("write len: {e}"))?;
    stream.write_all(&payload).map_err(|e| format!("write payload: {e}"))?;
    Ok(())
}

fn recv(stream: &mut UnixStream) -> Result<serde_json::Value, String> {
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf).map_err(|e| format!("read len: {e}"))?;
    let len = u32::from_le_bytes(len_buf) as usize;
    if len > 1_000_000 {
        return Err(format!("response too large: {len}"));
    }
    let mut buf = vec![0u8; len];
    stream.read_exact(&mut buf).map_err(|e| format!("read payload: {e}"))?;
    serde_json::from_slice(&buf).map_err(|e| format!("json decode: {e}"))
}

/// Authenticate a PIN/password against greetd and start the user session.
/// Returns Ok(true) on success, Ok(false) on auth failure, Err on protocol error.
pub fn authenticate_and_start_session(pin: &str) -> Result<bool, String> {
    let path = sock_path()?;
    let mut stream = UnixStream::connect(&path)
        .map_err(|e| format!("connect {path}: {e}"))?;

    let username = std::env::var("ATOMOS_GREETER_USER")
        .unwrap_or_else(|_| DEFAULT_USERNAME.to_string());

    send(&mut stream, &serde_json::json!({
        "type": "create_session",
        "username": username,
    }))?;

    let resp = recv(&mut stream)?;
    let resp_type = resp["type"].as_str().unwrap_or("");

    match resp_type {
        "auth_message" => {}
        "error" => {
            let desc = resp["description"].as_str().unwrap_or("unknown");
            return Err(format!("create_session error: {desc}"));
        }
        other => {
            return Err(format!("unexpected response to create_session: {other}"));
        }
    }

    send(&mut stream, &serde_json::json!({
        "type": "post_auth_message_response",
        "response": pin,
    }))?;

    let resp = recv(&mut stream)?;
    let resp_type = resp["type"].as_str().unwrap_or("");

    match resp_type {
        "success" => {}
        "error" => {
            let etype = resp["error_type"].as_str().unwrap_or("");
            if etype == "auth_error" {
                return Ok(false);
            }
            let desc = resp["description"].as_str().unwrap_or("unknown");
            return Err(format!("auth error: {desc}"));
        }
        "auth_message" => {
            // Multi-round auth not supported; cancel and report failure.
            let _ = send(&mut stream, &serde_json::json!({"type": "cancel_session"}));
            return Ok(false);
        }
        other => {
            return Err(format!("unexpected auth response: {other}"));
        }
    }

    let session_cmd = std::env::var("ATOMOS_SESSION_CMD")
        .unwrap_or_else(|_| DEFAULT_SESSION_CMD.to_string());
    let cmd_parts: Vec<&str> = session_cmd.split_whitespace().collect();

    send(&mut stream, &serde_json::json!({
        "type": "start_session",
        "cmd": cmd_parts,
        "env": [],
    }))?;

    let resp = recv(&mut stream)?;
    let resp_type = resp["type"].as_str().unwrap_or("");

    match resp_type {
        "success" => Ok(true),
        "error" => {
            let desc = resp["description"].as_str().unwrap_or("unknown");
            Err(format!("start_session error: {desc}"))
        }
        other => Err(format!("unexpected start_session response: {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sock_path_reflects_env() {
        // Test both set and unset in a single test to avoid parallel env races.
        std::env::set_var("GREETD_SOCK", "/tmp/test-greetd.sock");
        assert_eq!(sock_path().unwrap(), "/tmp/test-greetd.sock");
        std::env::remove_var("GREETD_SOCK");
        assert!(sock_path().is_err());
    }
}

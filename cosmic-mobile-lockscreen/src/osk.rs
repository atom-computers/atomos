#![allow(dead_code)]
use std::process::{Child, Command, Stdio};

pub fn has_squeekboard() -> bool {
    Command::new("sh")
        .arg("-c")
        .arg("command -v squeekboard >/dev/null 2>&1")
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

pub fn launch_squeekboard() -> Option<Child> {
    if !has_squeekboard() {
        return None;
    }
    Command::new("squeekboard")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn has_squeekboard_function_is_callable() {
        let _ = has_squeekboard();
    }
}

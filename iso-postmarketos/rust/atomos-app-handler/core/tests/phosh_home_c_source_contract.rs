//! Phosh `home.c` must implement the same shell lifecycle argv policy as
//! [`atomos_app_handler::shell_lifecycle_argv`]. Rust unit tests alone cannot
//! catch Phosh C regressions (e.g. `--show` on `PHOSH_HOME_STATE_UNFOLDED`).

use std::path::PathBuf;

fn home_c_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../phosh/phosh/src/home.c")
}

fn read_home_c() -> String {
    std::fs::read_to_string(home_c_path()).unwrap_or_else(|e| {
        panic!("read {}: {e}", home_c_path().display())
    })
}

fn strip_c_block_comments(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '/' && chars.peek() == Some(&'*') {
            chars.next();
            while let Some(ch) = chars.next() {
                if ch == '*' && chars.peek() == Some(&'/') {
                    chars.next();
                    break;
                }
            }
            continue;
        }
        out.push(c);
    }
    out
}

fn extract_function_body(src: &str, name: &str) -> String {
    let pattern = format!("atomos_phosh_sync_app_handler_lifecycle");
    let name = if name == "atomos_phosh_sync_app_handler_lifecycle" {
        pattern
    } else {
        name.to_string()
    };
    let sig = format!("{name} (");
    let start = src
        .find(&sig)
        .or_else(|| src.find(&format!("{name}(")))
        .unwrap_or_else(|| panic!("function {name} not found"));
    let brace_start = src[start..]
        .find('{')
        .map(|i| start + i)
        .expect("function opening brace");
    let mut depth = 0usize;
    for (idx, ch) in src[brace_start..].char_indices() {
        match ch {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return src[brace_start..=brace_start + idx].to_string();
                }
            }
            _ => {}
        }
    }
    panic!("unbalanced braces in {name}");
}

fn extract_switch_case(function_body: &str, case_label: &str) -> String {
    let needle = format!("case {case_label}:");
    let start = function_body
        .find(&needle)
        .unwrap_or_else(|| panic!("missing switch case {case_label} in lifecycle function"));
    let rest = &function_body[start + needle.len()..];
    let end = rest
        .find("case ")
        .or_else(|| rest.find("default:"))
        .unwrap_or(rest.len());
    strip_c_block_comments(&rest[..end])
}

#[test]
fn phosh_home_c_unfolded_must_not_assign_show_or_any_action() {
    let src = read_home_c();
    let lifecycle_fn =
        extract_function_body(&src, "atomos_phosh_sync_app_handler_lifecycle");
    let unfolded = extract_switch_case(&lifecycle_fn, "PHOSH_HOME_STATE_UNFOLDED");
    assert!(
        !unfolded.contains("action = \"--show\"") && !unfolded.contains("action = \"--show\";"),
        "UNFOLDED must not assign action=\"--show\" (post-unlock black overlay bug)"
    );
    assert!(
        !unfolded.contains("action ="),
        "UNFOLDED must not assign action; only FOLDED may spawn --hide"
    );
}

#[test]
fn phosh_home_c_folded_only_hides_switcher() {
    let src = read_home_c();
    let lifecycle_fn =
        extract_function_body(&src, "atomos_phosh_sync_app_handler_lifecycle");
    let folded = extract_switch_case(&lifecycle_fn, "PHOSH_HOME_STATE_FOLDED");
    assert!(
        folded.contains("action = \"--hide\"") || folded.contains("action = \"--hide\";"),
        "FOLDED must spawn --hide"
    );
    assert!(!folded.contains("--show"), "FOLDED must not use --show");
}

#[test]
fn phosh_home_c_lifecycle_function_never_spawns_show() {
    let src = read_home_c();
    let lifecycle_fn =
        extract_function_body(&src, "atomos_phosh_sync_app_handler_lifecycle");
    let tail = strip_c_block_comments(&lifecycle_fn);
    assert!(
        !tail.contains("action = \"--show\"") && !tail.contains("action = \"--show\";"),
        "lifecycle sync must not spawn --show"
    );
}

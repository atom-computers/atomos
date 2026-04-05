pub const MAX_LINES: i32 = 6;
pub const MIN_LINES: i32 = 1;
pub const LINE_HEIGHT_PX: i32 = 38;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LayoutState {
    pub source_lines: i32,
    pub visible_lines: i32,
    pub min_content_height: i32,
    pub max_content_height: i32,
    pub needs_scroll: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EnterKeyAction {
    Submit(String),
    InsertNewline,
    Noop,
}

pub fn line_count(text: &str) -> i32 {
    text.lines().count().max(1) as i32
}

pub fn layout_state_for_text(text: &str) -> LayoutState {
    let source_lines = line_count(text);
    let visible_lines = source_lines.clamp(MIN_LINES, MAX_LINES);
    LayoutState {
        source_lines,
        visible_lines,
        min_content_height: visible_lines * LINE_HEIGHT_PX,
        max_content_height: MAX_LINES * LINE_HEIGHT_PX,
        needs_scroll: source_lines > MAX_LINES,
    }
}

pub fn enter_action(message: &str, shift_pressed: bool) -> EnterKeyAction {
    if shift_pressed {
        return EnterKeyAction::InsertNewline;
    }

    let trimmed = message.trim();
    if trimmed.is_empty() {
        EnterKeyAction::Noop
    } else {
        EnterKeyAction::Submit(trimmed.to_string())
    }
}

pub fn parse_lifecycle_action(arg: Option<&str>) -> &'static str {
    match arg {
        Some("--show") => "--show",
        Some("--hide") => "--hide",
        _ => "run",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn line_count_empty_is_one() {
        assert_eq!(line_count(""), 1);
    }

    #[test]
    fn line_count_single_line() {
        assert_eq!(line_count("hello"), 1);
    }

    #[test]
    fn line_count_multi_line() {
        assert_eq!(line_count("a\nb\nc"), 3);
    }

    #[test]
    fn line_count_trailing_newline_matches_lines_behavior() {
        assert_eq!(line_count("hello\n"), 1);
    }

    #[test]
    fn layout_clamps_to_min_line() {
        let state = layout_state_for_text("");
        assert_eq!(state.visible_lines, MIN_LINES);
        assert_eq!(state.min_content_height, MIN_LINES * LINE_HEIGHT_PX);
        assert!(!state.needs_scroll);
    }

    #[test]
    fn layout_clamps_to_max_lines() {
        let state = layout_state_for_text("1\n2\n3\n4\n5\n6\n7\n8");
        assert_eq!(state.source_lines, 8);
        assert_eq!(state.visible_lines, MAX_LINES);
        assert_eq!(state.min_content_height, MAX_LINES * LINE_HEIGHT_PX);
        assert!(state.needs_scroll);
    }

    #[test]
    fn layout_no_scroll_at_exact_limit() {
        let state = layout_state_for_text("1\n2\n3\n4\n5\n6");
        assert_eq!(state.visible_lines, MAX_LINES);
        assert!(!state.needs_scroll);
    }

    #[test]
    fn enter_action_shift_is_newline() {
        assert_eq!(enter_action("hello", true), EnterKeyAction::InsertNewline);
    }

    #[test]
    fn enter_action_submit_trims_whitespace() {
        assert_eq!(
            enter_action("   hello world  ", false),
            EnterKeyAction::Submit("hello world".to_string())
        );
    }

    #[test]
    fn enter_action_empty_is_noop() {
        assert_eq!(enter_action("", false), EnterKeyAction::Noop);
        assert_eq!(enter_action("   \n\t", false), EnterKeyAction::Noop);
    }

    #[test]
    fn enter_action_preserves_internal_newlines_on_submit() {
        assert_eq!(
            enter_action("hello\nworld", false),
            EnterKeyAction::Submit("hello\nworld".to_string())
        );
    }

    #[test]
    fn parse_lifecycle_show() {
        assert_eq!(parse_lifecycle_action(Some("--show")), "--show");
    }

    #[test]
    fn parse_lifecycle_hide() {
        assert_eq!(parse_lifecycle_action(Some("--hide")), "--hide");
    }

    #[test]
    fn parse_lifecycle_default_run() {
        assert_eq!(parse_lifecycle_action(None), "run");
        assert_eq!(parse_lifecycle_action(Some("--unknown")), "run");
    }

    #[test]
    fn parse_lifecycle_empty_arg_defaults_run() {
        assert_eq!(parse_lifecycle_action(Some("")), "run");
    }
}

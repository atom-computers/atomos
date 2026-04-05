pub fn parse_bool_env_value(value: Result<String, std::env::VarError>) -> Option<bool> {
    match value.as_deref() {
        Ok("1") => Some(true),
        Ok("0") => Some(false),
        _ => None,
    }
}

pub fn env_flag_enabled(value: Result<String, std::env::VarError>) -> bool {
    matches!(parse_bool_env_value(value), Some(true))
}

pub fn desktop_like_from_monitor_geometry(geometry: Option<(i32, i32)>) -> bool {
    let Some((w, h)) = geometry else {
        return false;
    };
    let lo = w.min(h);
    let hi = w.max(h);
    lo >= 600 && hi >= 900
}

pub fn resolve_desktop_like_mode(
    desktop_like_override: Option<bool>,
    monitor_geometry: Option<(i32, i32)>,
) -> bool {
    desktop_like_override.unwrap_or_else(|| desktop_like_from_monitor_geometry(monitor_geometry))
}

pub fn should_use_layer_shell(desktop_like: bool, layer_shell_enabled: bool) -> bool {
    !desktop_like && layer_shell_enabled
}

pub fn theme_class(prefers_dark: bool) -> &'static str {
    if prefers_dark {
        "atomos-dark"
    } else {
        "atomos-light"
    }
}

#[cfg(test)]
mod tests {
    use super::{
        desktop_like_from_monitor_geometry, env_flag_enabled, parse_bool_env_value,
        resolve_desktop_like_mode, should_use_layer_shell, theme_class,
    };

    #[test]
    fn parse_bool_env_value_true() {
        assert_eq!(parse_bool_env_value(Ok("1".to_string())), Some(true));
    }

    #[test]
    fn parse_bool_env_value_false() {
        assert_eq!(parse_bool_env_value(Ok("0".to_string())), Some(false));
    }

    #[test]
    fn parse_bool_env_value_invalid() {
        assert_eq!(parse_bool_env_value(Ok("true".to_string())), None);
    }

    #[test]
    fn env_flag_enabled_only_when_one() {
        assert!(env_flag_enabled(Ok("1".to_string())));
        assert!(!env_flag_enabled(Ok("0".to_string())));
        assert!(!env_flag_enabled(Ok("yes".to_string())));
    }

    #[test]
    fn desktop_like_from_monitor_geometry_thresholds() {
        assert!(desktop_like_from_monitor_geometry(Some((900, 600))));
        assert!(desktop_like_from_monitor_geometry(Some((600, 900))));
        assert!(!desktop_like_from_monitor_geometry(Some((899, 599))));
    }

    #[test]
    fn desktop_like_from_monitor_geometry_none_is_false() {
        assert!(!desktop_like_from_monitor_geometry(None));
    }

    #[test]
    fn resolve_desktop_like_mode_prefers_override() {
        assert!(resolve_desktop_like_mode(Some(true), Some((300, 500))));
        assert!(!resolve_desktop_like_mode(Some(false), Some((1200, 900))));
    }

    #[test]
    fn resolve_desktop_like_mode_falls_back_to_geometry() {
        assert!(resolve_desktop_like_mode(None, Some((1200, 900))));
        assert!(!resolve_desktop_like_mode(None, Some((500, 800))));
    }

    #[test]
    fn should_use_layer_shell_mobile_only() {
        assert!(should_use_layer_shell(false, true));
        assert!(!should_use_layer_shell(true, true));
        assert!(!should_use_layer_shell(false, false));
    }

    #[test]
    fn theme_class_maps_dark_and_light() {
        assert_eq!(theme_class(true), "atomos-dark");
        assert_eq!(theme_class(false), "atomos-light");
    }
}


//! Shape-check the dynamic light theme assets shipped under
//! `data/atomos-home-bg/light-earth/`.

use std::path::PathBuf;

fn data_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("..")
        .join("data/atomos-home-bg/light-earth")
}

fn read_data_file(name: &str) -> String {
    let path = data_dir().join(name);
    assert!(
        path.exists(),
        "light-earth asset missing at {}",
        path.display()
    );
    std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("failed to read {}: {e}", path.display()))
}

#[test]
fn test_index_html_loads_index_js() {
    let html = read_data_file("index.html");
    assert!(
        html.contains("src=\"index.js\"") || html.contains("src='index.js'"),
        "light-earth index.html must load index.js bundle"
    );
}

#[test]
fn test_earth_client_uses_correct_defined_css_classes() {
    let tsx = read_data_file("EarthClient.tsx");
    
    // Catch the 0x0 canvas height/width rendering collapse:
    // It must use the defined CSS class 'globe-offset' instead of Tailwind classes
    // which are un-defined in index.html (as we are not loading the full tailwind on device).
    assert!(
        tsx.contains("globe-offset"),
        "EarthClient.tsx must use the 'globe-offset' CSS class defined in index.html"
    );

    assert!(
        !tsx.contains("-translate-y-1/5"),
        "EarthClient.tsx must avoid Tailwind translate-y classes which are undefined in index.html"
    );
    
    // Ensure the container is given full dimensions
    assert!(
        tsx.contains("w-screen") && tsx.contains("h-screen"),
        "EarthClient.tsx must use full screen dimensions so that the canvas does not collapse to 0x0 height"
    );
}

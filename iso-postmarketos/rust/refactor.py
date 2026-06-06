import os
import re

crates = [
    "atomos-lockscreen",
    "atomos-quick-settings",
    "atomos-home-bg",
    "atomos-app-handler",
    "atomos-overview-chat-ui",
    "atomos-top-bar"
]

for crate in crates:
    src_path = f"{crate}/app-egui/src/main.rs"
    if not os.path.exists(src_path):
        continue
    
    with open(src_path, "r") as f:
        content = f.read()
    
    # Make structs pub
    content = re.sub(r'struct (\w+App)\b', r'pub struct \1', content)
    
    # In TopBarApp, make new() pub
    content = re.sub(r'fn new\(\)', r'pub fn new()', content)
    
    # We want to remove the main function to avoid unused warnings in lib, 
    # but for now we can just slap it in lib.rs and ignore main() or let it be dead code.
    # Actually, main is not allowed in a lib if it conflicts, but usually it's just dead code if it's named main.
    # Let's rename main to `dummy_main` to avoid issues.
    content = re.sub(r'fn main\(\)', r'fn dummy_main()', content)
    content = re.sub(r'async fn main\(\)', r'async fn dummy_main()', content)
    
    dest_path = f"{crate}/app-egui/src/lib.rs"
    with open(dest_path, "w") as f:
        f.write(content)
    print(f"Refactored {crate}")

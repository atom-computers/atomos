def fix_qs_and_ls():
    for crate in ["atomos-quick-settings", "atomos-lockscreen", "atomos-app-handler", "atomos-overview-chat-ui"]:
        p = f"{crate}/app-egui/src/lib.rs"
        with open(p, "r") as f:
            content = f.read()
        content = content.replace("_ui.set_min_size", "ui.set_min_size")
        with open(p, "w") as f:
            f.write(content)

def fix_chat_ui():
    p = "atomos-overview-chat-ui/app-egui/src/lib.rs"
    with open(p, "r") as f:
        lines = f.readlines()
    
    # Let's just remove the last '}' that is extraneous.
    # We'll pop the last line if it's '}'
    with open(p, "w") as f:
        for i, line in enumerate(lines):
            if i == len(lines) - 2 and line.strip() == "}":
                continue # Skip the extraneous brace
            f.write(line)

fix_qs_and_ls()
fix_chat_ui()

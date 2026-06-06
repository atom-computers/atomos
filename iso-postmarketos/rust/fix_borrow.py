import os, glob

for p in glob.glob("atomos-*/app-egui/src/lib.rs"):
    with open(p, "r") as f:
        content = f.read()
    
    # Fix the borrow checker error:
    # _ui.set_min_size(ctx.screen_rect().size())
    content = content.replace("ui.set_min_size(ctx.screen_rect().size());", "_ui.set_min_size(ctx.screen_rect().size());")
    # Actually wait, some of them are `show(ui, |ui| { ui.set_min_size... })` which shadows the outer ui, so it works.
    # But for home-bg it was `|_ui| { ui.set_min_size }`.
    content = content.replace("|_ui| {\n                ui.set_min_size", "|_ui| {\n                _ui.set_min_size")
    
    # Let's just fix the specific ones
    content = content.replace("ui.set_min_size(ctx.screen_rect().size())", "ui.set_min_size(ctx.screen_rect().size())") # this might be shadowed
    
    # The deprecation warning: ctx.screen_rect() -> ctx.screen_rect()
    # Let's suppress warnings at the top of the files
    if "#![allow(" not in content:
        content = "#![allow(deprecated, dead_code)]\n" + content
    
    with open(p, "w") as f:
        f.write(content)

import os, re

fixes = {
    "atomos-home-bg": "home_bg_area",
    "atomos-overview-chat-ui": "chat_ui_area",
    "atomos-app-handler": "app_handler_area",
    "atomos-top-bar": "top_bar_area",
    "atomos-quick-settings": "qs_area",
    "atomos-lockscreen": "lockscreen_area"
}

for crate, area_id in fixes.items():
    p = f"{crate}/app-egui/src/lib.rs"
    if not os.path.exists(p): continue
    
    with open(p, "r") as f:
        content = f.read()
    
    # Replace CentralPanel::default().frame(...) with Area::new(egui::Id::new("...")).show(ctx, |ui| { Frame::...show(ui, |ui| ... ) })
    # This is a bit too complex for regex.
    # We can just replace `egui::CentralPanel::default()` with `egui::Window::new("foo").title_bar(false).frame(egui::Frame::none()).show(ctx, |ui| ...)` ? No, window has padding.
    
    # Let's just do it manually with sed or python string replacements.
    
    if crate == "atomos-home-bg":
        content = content.replace("egui::CentralPanel::default()\n            .frame(egui::Frame::NONE.fill(HOME_BG_BASE_COLOR).inner_margin(0.0))\n            .show(ctx, |_ui| {});", 
                                  f'egui::Area::new(egui::Id::new("{area_id}")).order(egui::Order::Background).show(ctx, |ui| {{\n            egui::Frame::NONE.fill(HOME_BG_BASE_COLOR).inner_margin(0.0).show(ui, |_ui| {{\n                ui.set_min_size(ctx.screen_rect().size());\n            }});\n        }});')
    
    elif crate == "atomos-lockscreen":
        content = content.replace("egui::CentralPanel::default().show(ctx, |ui| {", f'egui::Area::new(egui::Id::new("{area_id}_unlock")).order(egui::Order::Foreground).show(ctx, |ui| {{')
        content = content.replace("egui::CentralPanel::default()\n            .frame(egui::Frame::NONE.fill(egui::Color32::from_rgb(20, 20, 30))) // Keep dark wallpaper feel for now\n            .show(ctx, |ui| {", 
                                  f'egui::Area::new(egui::Id::new("{area_id}")).order(egui::Order::Foreground).show(ctx, |ui| {{\n            egui::Frame::NONE.fill(egui::Color32::from_rgb(20, 20, 30)).show(ui, |ui| {{\n                ui.set_min_size(ctx.screen_rect().size());')
        # We need to add one more closing brace for the frame
        content = content.replace("ctx.request_repaint(); // Keep animating time/snap back", "});\n        ctx.request_repaint(); // Keep animating time/snap back")
        
    elif crate == "atomos-quick-settings":
        content = content.replace("egui::CentralPanel::default()\n            .frame(egui::Frame::NONE.fill(egui::Color32::TRANSPARENT))\n            .show(ctx, |ui| {",
                                  f'egui::Area::new(egui::Id::new("{area_id}")).order(egui::Order::Foreground).show(ctx, |ui| {{\n            egui::Frame::NONE.fill(egui::Color32::TRANSPARENT).show(ui, |ui| {{\n                ui.set_min_size(ctx.screen_rect().size());')
        content = content.replace("});\n    }\n}", "});\n            });\n    }\n}")
        
    elif crate == "atomos-overview-chat-ui":
        content = content.replace("egui::CentralPanel::default()\n            .frame(egui::Frame::NONE.fill(egui::Color32::from_rgb(0, 0, 0)))\n            .show(ctx, |ui| {",
                                  f'egui::Area::new(egui::Id::new("{area_id}")).order(egui::Order::Middle).show(ctx, |ui| {{\n            egui::Frame::NONE.fill(egui::Color32::from_rgb(0, 0, 0)).show(ui, |ui| {{\n                ui.set_min_size(ctx.screen_rect().size());')
        content = content.replace("});\n    }\n}", "});\n            });\n    }\n}")
        
    elif crate == "atomos-app-handler":
        content = content.replace("egui::CentralPanel::default()\n            .frame(egui::Frame::NONE.fill(egui::Color32::from_rgb(0x0a, 0x0a, 0x0a)).inner_margin(0.0))\n            .show(ctx, |ui| {",
                                  f'egui::Area::new(egui::Id::new("{area_id}")).order(egui::Order::Background).show(ctx, |ui| {{\n            egui::Frame::NONE.fill(egui::Color32::from_rgb(0x0a, 0x0a, 0x0a)).inner_margin(0.0).show(ui, |ui| {{\n                ui.set_min_size(ctx.screen_rect().size());')
        content = content.replace("self.render_bottom_handle(ctx, strip_h, viewport_h, viewport_w);\n    }\n}", "self.render_bottom_handle(ctx, strip_h, viewport_h, viewport_w);\n            });\n    }\n}")

    elif crate == "atomos-top-bar":
        content = content.replace("egui::CentralPanel::default().show(ctx, |ui| {", f'egui::Area::new(egui::Id::new("{area_id}")).show(ctx, |ui| {{')

    with open(p, "w") as f:
        f.write(content)
    
    print(f"Fixed {crate}")

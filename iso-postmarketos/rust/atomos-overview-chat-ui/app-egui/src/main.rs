use atomos_overview_chat_ui::{enter_action, layout_state_for_text, EnterKeyAction, MAX_LINES};
use eframe::egui;

fn main() -> eframe::Result<()> {
    let native_options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("AtomOS Overview Chat (dev preview)")
            .with_inner_size([900.0, 640.0]),
        ..Default::default()
    };

    eframe::run_native(
        "AtomOS Overview Chat (dev preview)",
        native_options,
        Box::new(|_cc| Ok(Box::<DevPreviewApp>::default())),
    )
}

#[derive(Default)]
struct DevPreviewApp {
    text: String,
    last_submit: Option<String>,
}

impl eframe::App for DevPreviewApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        egui::CentralPanel::default()
            .frame(
                egui::Frame::default()
                    .fill(egui::Color32::from_rgb(16, 20, 30))
                    .inner_margin(0.0),
            )
            .show(ctx, |ui| {
                ui.with_layout(egui::Layout::top_down(egui::Align::LEFT), |ui| {
                    ui.add_space(ui.available_height().max(0.0) - 180.0);

                    let layout = layout_state_for_text(&self.text);
                    let rows = layout.visible_lines.clamp(1, MAX_LINES) as usize;
                    let desired_h = (rows as f32 * 22.0) + 16.0;

                    ui.horizontal(|ui| {
                        let max_w = (ui.available_width() - 120.0).max(320.0);
                        let response = ui.add_sized(
                            [max_w, desired_h],
                            egui::TextEdit::multiline(&mut self.text)
                                .hint_text("Message...")
                                .desired_rows(rows),
                        );
                        let send_clicked = ui.button("Send").clicked();

                        if response.has_focus() {
                            let enter_pressed = ui.input(|i| i.key_pressed(egui::Key::Enter));
                            let shift_pressed = ui.input(|i| i.modifiers.shift);
                            if enter_pressed {
                                match enter_action(&self.text, shift_pressed) {
                                    EnterKeyAction::Submit(payload) => {
                                        self.last_submit = Some(payload);
                                        self.text.clear();
                                    }
                                    EnterKeyAction::Noop => {}
                                    EnterKeyAction::InsertNewline => {}
                                }
                            }
                        }

                        if send_clicked {
                            if let EnterKeyAction::Submit(payload) = enter_action(&self.text, false) {
                                self.last_submit = Some(payload);
                                self.text.clear();
                            }
                        }
                    });

                    ui.add_space(8.0);
                    ui.label(
                        egui::RichText::new(
                            "Preview notes: Shift+Enter keeps editing; Enter/Send simulates submit path.",
                        )
                        .color(egui::Color32::LIGHT_GRAY),
                    );

                    if let Some(last) = &self.last_submit {
                        ui.label(
                            egui::RichText::new(format!("Last submit: {last}"))
                                .color(egui::Color32::from_rgb(128, 224, 178)),
                        );
                    }
                });
            });
    }
}

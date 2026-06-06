use eframe::egui;

use atomos_home_bg_egui::CombinedPreviewApp as HomeBgApp;
use atomos_overview_chat_ui_egui::DevPreviewApp as ChatUiApp;
use atomos_app_handler_egui::PreviewApp as AppHandlerApp;
use atomos_top_bar_egui::TopBarApp;
use atomos_quick_settings_egui::QuickSettingsApp;
use atomos_lockscreen_egui::LockscreenApp;

#[tokio::main]
async fn main() -> eframe::Result<()> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([400.0, 800.0])
            .with_title("AtomOS Unified Shell Preview"),
        ..Default::default()
    };
    eframe::run_native(
        "AtomOS Unified Preview",
        options,
        Box::new(|_cc| Ok(Box::new(UnifiedPreview::new()))),
    )
}

struct UnifiedPreview {
    home_bg: HomeBgApp,
    chat_ui: ChatUiApp,
    app_handler: AppHandlerApp,
    top_bar: TopBarApp,
    quick_settings: QuickSettingsApp,
    lockscreen: LockscreenApp,
    
    // Interactions
    qs_open: bool,
}

impl UnifiedPreview {
    fn new() -> Self {
        Self {
            home_bg: HomeBgApp::default(),
            chat_ui: ChatUiApp::default(),
            app_handler: AppHandlerApp::default(),
            top_bar: TopBarApp::new(),
            quick_settings: QuickSettingsApp::default(),
            lockscreen: LockscreenApp::default(),
            qs_open: false,
        }
    }
}

impl eframe::App for UnifiedPreview {
    fn update(&mut self, ctx: &egui::Context, frame: &mut eframe::Frame) {
        use eframe::App;
        
        // Z-order:
        // 1. Home BG (Area)
        // 2. Chat UI (Area)
        // 3. App Handler (Area)
        // 4. Top Bar (TopBottomPanel)
        // 5. Quick Settings (Area)
        // 6. Lockscreen (Area)
        
        // Apply global style
        let mut visuals = egui::Visuals::dark();
        visuals.window_fill = egui::Color32::from_rgba_premultiplied(20, 20, 20, 220);
        visuals.window_stroke = egui::Stroke::new(1.0, egui::Color32::from_rgba_premultiplied(255, 255, 255, 20));
        ctx.set_visuals(visuals);
        
        self.home_bg.update(ctx, frame);
        self.chat_ui.update(ctx, frame);
        self.app_handler.update(ctx, frame);
        self.top_bar.update(ctx, frame);
        
        // Listen for a downward swipe near the top of the screen to open Quick Settings
        // or an upward swipe to close it.
        let mut pointer_y_delta = 0.0;
        ctx.input(|i| {
            if i.pointer.is_decidedly_dragging() {
                pointer_y_delta = i.pointer.delta().y;
            }
        });
        
        if pointer_y_delta > 5.0 && !self.qs_open {
            self.qs_open = true;
        } else if pointer_y_delta < -5.0 && self.qs_open {
            self.qs_open = false;
        }
            
        if self.qs_open {
            self.quick_settings.update(ctx, frame);
        }
        
        self.lockscreen.update(ctx, frame);
    }
}

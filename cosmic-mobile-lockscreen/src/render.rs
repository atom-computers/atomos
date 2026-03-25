use chrono::Local;
use tiny_skia::{
    Color, FillRule, GradientStop, LinearGradient, Paint, PathBuilder, Pixmap, PixmapPaint, Point,
    Rect, SpreadMode, Transform,
};

const FONT_PATHS: &[&str] = &[
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/ttf-dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
];

const WALLPAPER_PATHS: &[&str] = &[
    "/usr/share/backgrounds/atomos/gargantua-black.jpg",
    "/usr/share/backgrounds/postmarketos.jpg",
];

pub const MAX_PIN_DOTS: usize = 6;

pub struct Renderer {
    font: Option<fontdue::Font>,
    wallpaper: Option<Pixmap>,
}

impl Renderer {
    pub fn new() -> Self {
        let font = FONT_PATHS
            .iter()
            .find_map(|p| std::fs::read(p).ok())
            .and_then(|data| {
                fontdue::Font::from_bytes(data, fontdue::FontSettings::default()).ok()
            });

        let wallpaper = WALLPAPER_PATHS
            .iter()
            .find_map(|p| std::fs::read(p).ok())
            .and_then(|data| decode_jpeg(&data));

        Self { font, wallpaper }
    }

    /// Render the full phone-style lock screen to ARGB8888 pixel data
    /// ready for a Wayland SHM buffer (little-endian BGRA byte order).
    pub fn render(&self, width: u32, height: u32, pin_len: usize, error: &str) -> Vec<u8> {
        let mut pixmap = Pixmap::new(width, height).expect("pixmap");
        let scale = width as f32 / 1080.0;

        self.draw_background(&mut pixmap);

        // Semi-transparent dark overlay so UI elements remain readable on any wallpaper.
        if self.wallpaper.is_some() {
            if let Some(rect) = Rect::from_xywh(0.0, 0.0, width as f32, height as f32) {
                let mut paint = Paint::default();
                paint.set_color_rgba8(0, 0, 0, 120);
                pixmap.fill_rect(rect, &paint, Transform::identity(), None);
            }
        }

        let now = Local::now();
        let time_str = now.format("%H:%M").to_string();
        let date_str = now.format("%A, %e %B").to_string();

        let cx = width as f32 / 2.0;
        let mut y = height as f32 * 0.14;

        let time_size = 96.0 * scale;
        self.draw_text_centered(&mut pixmap, &time_str, time_size, cx, y, [255, 255, 255, 255]);
        y += time_size * 0.85;

        let date_size = 22.0 * scale;
        self.draw_text_centered(&mut pixmap, &date_str, date_size, cx, y, [230, 230, 255, 200]);
        y += date_size * 2.5;

        let label_size = 20.0 * scale;
        self.draw_text_centered(
            &mut pixmap,
            "Enter Password",
            label_size,
            cx,
            y,
            [255, 255, 255, 220],
        );
        y += label_size * 2.0;

        let dot_r = 6.0 * scale;
        let dot_gap = 22.0 * scale;
        let dots_total = MAX_PIN_DOTS as f32 * dot_gap;
        let dot_start_x = cx - dots_total / 2.0 + dot_gap / 2.0;
        for i in 0..MAX_PIN_DOTS {
            let filled = i < pin_len;
            let dx = dot_start_x + i as f32 * dot_gap;
            draw_circle(
                &mut pixmap,
                dx,
                y,
                dot_r,
                if filled {
                    [255, 255, 255, 255]
                } else {
                    [255, 255, 255, 100]
                },
            );
        }
        y += dot_r * 2.0 + 18.0 * scale;

        if !error.is_empty() {
            self.draw_text_centered(
                &mut pixmap,
                error,
                16.0 * scale,
                cx,
                y,
                [255, 160, 160, 255],
            );
            y += 24.0 * scale;
        }

        y += 10.0 * scale;
        let btn_r = 36.0 * scale;
        let btn_gap = 28.0 * scale;
        let digit_size = 28.0 * scale;
        let small_size = 16.0 * scale;
        let row_h = btn_r * 2.0 + btn_gap;

        let cols: [f32; 3] = [cx - (btn_r * 2.0 + btn_gap), cx, cx + (btn_r * 2.0 + btn_gap)];
        let digit_rows: [[char; 3]; 3] = [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9']];

        for (ri, digits) in digit_rows.iter().enumerate() {
            let ry = y + ri as f32 * row_h;
            for (ci, &d) in digits.iter().enumerate() {
                self.draw_digit_button(&mut pixmap, cols[ci], ry, btn_r, d, digit_size);
            }
        }

        let last_y = y + 3.0 * row_h;
        self.draw_text_centered(
            &mut pixmap,
            "Emergency",
            small_size,
            cols[0],
            last_y,
            [255, 255, 255, 180],
        );
        self.draw_digit_button(&mut pixmap, cols[1], last_y, btn_r, '0', digit_size);
        self.draw_text_centered(
            &mut pixmap,
            "Cancel",
            small_size,
            cols[2],
            last_y,
            [255, 255, 255, 180],
        );

        let mut data = pixmap.data().to_vec();
        for pixel in data.chunks_exact_mut(4) {
            pixel.swap(0, 2);
        }
        data
    }

    fn draw_background(&self, pixmap: &mut Pixmap) {
        if let Some(wp) = &self.wallpaper {
            let sw = pixmap.width() as f32;
            let sh = pixmap.height() as f32;
            let iw = wp.width() as f32;
            let ih = wp.height() as f32;

            // "Zoom" scaling: cover the entire surface, crop excess.
            let scale = (sw / iw).max(sh / ih);
            let tx = (sw - iw * scale) / 2.0;
            let ty = (sh - ih * scale) / 2.0;

            pixmap.draw_pixmap(
                0,
                0,
                wp.as_ref(),
                &PixmapPaint::default(),
                Transform::from_scale(scale, scale).post_translate(tx, ty),
                None,
            );
        } else {
            self.draw_gradient(pixmap);
        }
    }

    fn draw_gradient(&self, pixmap: &mut Pixmap) {
        let w = pixmap.width() as f32;
        let h = pixmap.height() as f32;
        let gradient = LinearGradient::new(
            Point::from_xy(0.0, 0.0),
            Point::from_xy(0.0, h),
            vec![
                GradientStop::new(0.0, Color::from_rgba8(18, 12, 48, 255)),
                GradientStop::new(0.25, Color::from_rgba8(48, 24, 82, 255)),
                GradientStop::new(0.45, Color::from_rgba8(108, 42, 108, 255)),
                GradientStop::new(0.65, Color::from_rgba8(178, 68, 92, 255)),
                GradientStop::new(0.82, Color::from_rgba8(224, 112, 68, 255)),
                GradientStop::new(1.0, Color::from_rgba8(248, 168, 72, 255)),
            ],
            SpreadMode::Pad,
            Transform::identity(),
        );
        if let Some(shader) = gradient {
            let mut paint = Paint::default();
            paint.shader = shader;
            if let Some(rect) = Rect::from_xywh(0.0, 0.0, w, h) {
                pixmap.fill_rect(rect, &paint, Transform::identity(), None);
            }
        } else {
            pixmap.fill(Color::from_rgba8(18, 12, 48, 255));
        }
    }

    fn draw_digit_button(
        &self,
        pixmap: &mut Pixmap,
        cx: f32,
        cy: f32,
        radius: f32,
        digit: char,
        font_size: f32,
    ) {
        draw_circle(pixmap, cx, cy, radius, [255, 255, 255, 56]);
        let s = digit.to_string();
        self.draw_text_centered(pixmap, &s, font_size, cx, cy, [255, 255, 255, 255]);
    }

    fn draw_text_centered(
        &self,
        pixmap: &mut Pixmap,
        text: &str,
        size: f32,
        center_x: f32,
        center_y: f32,
        rgba: [u8; 4],
    ) {
        let font = match &self.font {
            Some(f) => f,
            None => return,
        };
        let total_w: f32 = text.chars().map(|c| font.metrics(c, size).advance_width).sum();
        let ascent = size * 0.75;
        let mut x = center_x - total_w / 2.0;
        let baseline = center_y + ascent * 0.35;

        for ch in text.chars() {
            let (metrics, bitmap) = font.rasterize(ch, size);
            let gx0 = x as i32 + metrics.xmin;
            let gy0 = baseline as i32 - metrics.height as i32 - metrics.ymin;

            for row in 0..metrics.height {
                for col in 0..metrics.width {
                    let alpha = bitmap[row * metrics.width + col];
                    if alpha == 0 {
                        continue;
                    }
                    let px = gx0 + col as i32;
                    let py = gy0 + row as i32;
                    if px < 0
                        || py < 0
                        || px >= pixmap.width() as i32
                        || py >= pixmap.height() as i32
                    {
                        continue;
                    }
                    let a = (alpha as f32 / 255.0) * (rgba[3] as f32 / 255.0);
                    let idx = (py as usize * pixmap.width() as usize + px as usize) * 4;
                    let d = pixmap.data_mut();
                    d[idx] = blend_ch(d[idx], rgba[0], a);
                    d[idx + 1] = blend_ch(d[idx + 1], rgba[1], a);
                    d[idx + 2] = blend_ch(d[idx + 2], rgba[2], a);
                    d[idx + 3] = 255;
                }
            }
            x += metrics.advance_width;
        }
    }
}

fn blend_ch(dst: u8, src: u8, a: f32) -> u8 {
    (dst as f32 * (1.0 - a) + src as f32 * a) as u8
}

fn draw_circle(pixmap: &mut Pixmap, cx: f32, cy: f32, r: f32, rgba: [u8; 4]) {
    let mut pb = PathBuilder::new();
    pb.push_circle(cx, cy, r);
    if let Some(path) = pb.finish() {
        let mut paint = Paint::default();
        paint.set_color_rgba8(rgba[0], rgba[1], rgba[2], rgba[3]);
        paint.anti_alias = true;
        pixmap.fill_path(&path, &paint, FillRule::Winding, Transform::identity(), None);
    }
}

/// Decode a JPEG file to a tiny-skia Pixmap (RGBA premultiplied).
fn decode_jpeg(data: &[u8]) -> Option<Pixmap> {
    let mut decoder = jpeg_decoder::Decoder::new(std::io::Cursor::new(data));
    let pixels = decoder.decode().ok()?;
    let info = decoder.info()?;
    let w = info.width as u32;
    let h = info.height as u32;

    let mut pixmap = Pixmap::new(w, h)?;
    let dst = pixmap.data_mut();

    match info.pixel_format {
        jpeg_decoder::PixelFormat::RGB24 => {
            for (i, chunk) in pixels.chunks_exact(3).enumerate() {
                let off = i * 4;
                if off + 3 < dst.len() {
                    dst[off] = chunk[0];
                    dst[off + 1] = chunk[1];
                    dst[off + 2] = chunk[2];
                    dst[off + 3] = 255;
                }
            }
        }
        jpeg_decoder::PixelFormat::L8 => {
            for (i, &v) in pixels.iter().enumerate() {
                let off = i * 4;
                if off + 3 < dst.len() {
                    dst[off] = v;
                    dst[off + 1] = v;
                    dst[off + 2] = v;
                    dst[off + 3] = 255;
                }
            }
        }
        _ => return None,
    }

    Some(pixmap)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_without_panic() {
        let r = Renderer::new();
        let data = r.render(360, 640, 3, "");
        assert_eq!(data.len(), 360 * 640 * 4);
    }

    #[test]
    fn renders_with_error_message() {
        let r = Renderer::new();
        let data = r.render(1080, 2340, 0, "Wrong PIN");
        assert_eq!(data.len(), 1080 * 2340 * 4);
    }

    #[test]
    fn gradient_fallback_when_no_wallpaper() {
        let r = Renderer { font: None, wallpaper: None };
        let data = r.render(100, 200, 0, "");
        assert_eq!(data.len(), 100 * 200 * 4);
        assert!(data.iter().any(|&b| b != 0), "should not be all black");
    }
}

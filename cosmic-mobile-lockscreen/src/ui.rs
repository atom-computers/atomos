use crate::engine::LockState;
use chrono::Local;
use iced::gradient::{self, Gradient};
use iced::widget::button::{self, Status};
use iced::widget::{button as btn, column, container, row, text};
use iced::{Alignment, Background, Border, Color, Element, Length, Shadow};

/// User actions from the lockscreen (for iced `Application` wiring).
#[allow(dead_code)] // Full set for future iced loop; current harness only exercises `Digit`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UiMessage {
    Digit(char),
    Backspace,
    Clear,
    Submit,
    Emergency,
    Cancel,
}

/// Phosh-style PIN length for dot indicators (matches common phone lock UIs).
pub const DEFAULT_PIN_DOT_COUNT: usize = 4;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LockscreenComponent {
    pub time_label: String,
    pub date_label: String,
    pub entered_pin: String,
    pub unlock_status: String,
    pub pin_dot_count: usize,
}

impl LockscreenComponent {
    pub fn from_state(state: &LockState) -> Self {
        let now = Local::now();
        Self {
            time_label: now.format("%H:%M").to_string(),
            date_label: now.format("%A, %e %B").to_string(),
            entered_pin: String::new(),
            unlock_status: state.unlock_status.clone(),
            pin_dot_count: DEFAULT_PIN_DOT_COUNT,
        }
    }

    /// Sunset-style backdrop similar to the reference mock (purple → warm orange).
    fn screen_background() -> Background {
        let linear = gradient::Linear::new(std::f32::consts::FRAC_PI_2)
            .add_stop(0.0, Color::from_rgb8(52, 28, 88))
            .add_stop(0.55, Color::from_rgb8(118, 48, 128))
            .add_stop(1.0, Color::from_rgb8(232, 118, 62));
        Background::Gradient(Gradient::Linear(linear))
    }

    fn headline_text(content: String, size: f32) -> Element<'static, UiMessage> {
        text(content).size(size).color(Color::WHITE).into()
    }

    fn pin_dot_row(&self) -> Element<'_, UiMessage> {
        let len = self.entered_pin.chars().count().min(self.pin_dot_count);
        let mut r = row![].spacing(14).align_y(Alignment::Center);
        for i in 0..self.pin_dot_count {
            let filled = i < len;
            let label = if filled { "●" } else { "○" };
            r = r.push(
                text(label)
                    .size(16)
                    .color(if filled {
                        Color::WHITE
                    } else {
                        Color::from_rgba(1.0, 1.0, 1.0, 0.45)
                    }),
            );
        }
        r.into()
    }

    fn circle_digit_button(d: char) -> Element<'static, UiMessage> {
        let cell = 62.0_f32;
        let base = Color::from_rgba(1.0, 1.0, 1.0, 0.22);
        let hover = Color::from_rgba(1.0, 1.0, 1.0, 0.38);
        let pressed = Color::from_rgba(1.0, 1.0, 1.0, 0.62);

        btn(
            container(
                text(d.to_string())
                    .size(24)
                    .color(Color::from_rgb8(28, 28, 36)),
            )
            .center_x(Length::Fill)
            .center_y(Length::Fill)
            .width(Length::Fixed(cell))
            .height(Length::Fixed(cell)),
        )
        .on_press(UiMessage::Digit(d))
        .padding(0)
        .width(Length::Fixed(cell))
        .height(Length::Fixed(cell))
        .style(move |_theme, status| {
            let bg = match status {
                Status::Pressed => pressed,
                Status::Hovered => hover,
                Status::Active => base,
                Status::Disabled => base,
            };
            button::Style {
                background: Some(Background::Color(bg)),
                text_color: Color::WHITE,
                border: Border::default().rounded(999.0),
                shadow: Shadow::default(),
            }
        })
        .into()
    }

    fn keypad_row_digits(keys: &[char]) -> Element<'static, UiMessage> {
        let mut r = row![].spacing(18).align_y(Alignment::Center);
        for k in keys {
            r = r.push(Self::circle_digit_button(*k));
        }
        r.into()
    }

    fn text_action(label: &'static str, msg: UiMessage) -> Element<'static, UiMessage> {
        btn(text(label).size(15).color(Color::WHITE))
            .on_press(msg)
            .padding([10, 6])
            .style(|_theme, status| {
                let alpha = match status {
                    Status::Hovered => 0.28_f32,
                    Status::Pressed => 0.45,
                    _ => 0.0,
                };
                button::Style {
                    background: Some(Background::Color(Color::from_rgba(
                        1.0, 1.0, 1.0, alpha,
                    ))),
                    text_color: Color::WHITE,
                    border: Border::default(),
                    shadow: Shadow::default(),
                }
            })
            .into()
    }

    /// Full-screen layout aligned with the “time + password + circular keypad” mock.
    pub fn view(&self) -> Element<'_, UiMessage> {
        let subtitle = if self.unlock_status.is_empty() {
            None
        } else {
            Some(self.unlock_status.clone())
        };

        let mut body = column![
            Self::headline_text(self.time_label.clone(), 64.0),
            Self::headline_text(self.date_label.clone(), 20.0),
            Self::headline_text("Enter Password".to_string(), 18.0),
            self.pin_dot_row(),
        ]
        .spacing(14)
        .align_x(Alignment::Center);

        if let Some(s) = subtitle {
            body = body.push(
                text(s)
                    .size(14)
                    .color(Color::from_rgb8(255, 200, 200)),
            );
        }

        let keypad = column![
            Self::keypad_row_digits(&['1', '2', '3']),
            Self::keypad_row_digits(&['4', '5', '6']),
            Self::keypad_row_digits(&['7', '8', '9']),
            row![
                Self::text_action("Emergency", UiMessage::Emergency),
                Self::circle_digit_button('0'),
                Self::text_action("Cancel", UiMessage::Cancel),
            ]
            .spacing(28)
            .align_y(Alignment::Center),
        ]
        .spacing(20)
        .align_x(Alignment::Center);

        let content = column![body, keypad]
            .spacing(36)
            .align_x(Alignment::Center)
            .width(Length::Fill)
            .max_width(420);

        container(content)
            .width(Length::Fill)
            .height(Length::Fill)
            .center_x(Length::Fill)
            .center_y(Length::Fill)
            .padding(24)
            .style(|_theme| {
                iced::widget::container::Style::default()
                    .background(Self::screen_background())
            })
            .into()
    }
}

/// ASCII preview for CLI / tests (structure mirrors the iced layout).
pub fn render_lockscreen_view(state: &LockState) -> String {
    let now = Local::now();
    let time_line = now.format("%H:%M").to_string();
    let date_line = now.format("%A, %e %B").to_string();
    let entered_len = 0_usize;
    let max_dots = DEFAULT_PIN_DOT_COUNT;
    let mut dots = String::new();
    for i in 0..max_dots {
        if i < entered_len {
            dots.push('●');
        } else {
            dots.push('○');
        }
        if i + 1 < max_dots {
            dots.push(' ');
        }
    }
    let err = if state.unlock_status.is_empty() {
        String::new()
    } else {
        format!("\n(error) {}\n", state.unlock_status)
    };

    format!(
        concat!(
            "{time_line}\n",
            "{date_line}\n",
            "\n",
            "Enter Password\n",
            "{dots}\n",
            "{err}",
            "\n",
            "    ( 1 ) ( 2 ) ( 3 )\n",
            "    ( 4 ) ( 5 ) ( 6 )\n",
            "    ( 7 ) ( 8 ) ( 9 )\n",
            " Emergency    ( 0 )    Cancel\n",
        ),
        time_line = time_line,
        date_line = date_line,
        dots = dots,
        err = err,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::LockState;

    #[test]
    fn ascii_preview_matches_time_password_keypad_shape() {
        let state = LockState {
            locked: true,
            unlock_required: true,
            active_page: "keypad",
            unlock_status: String::new(),
        };
        let view = render_lockscreen_view(&state);
        assert!(view.contains("Enter Password"));
        assert_eq!(view.matches('○').count(), DEFAULT_PIN_DOT_COUNT);
        assert!(view.contains("Emergency"));
        assert!(view.contains("Cancel"));
    }

    #[test]
    fn iced_view_is_constructible() {
        let state = LockState {
            locked: true,
            unlock_required: true,
            active_page: "keypad",
            unlock_status: String::new(),
        };
        let ui = LockscreenComponent::from_state(&state);
        let _view = ui.view();
    }
}

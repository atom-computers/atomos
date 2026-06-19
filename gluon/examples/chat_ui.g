-- Chat UI: composited interface with header, messages, input bar
-- Demonstrates: UI composition, touch input, keyboard input, draw_text, fill, blend

region touch:    region input [x: 720px, y: 1440px, z: 1layer, t: 1frame] of F32x4
    @ ShortTerm @ ReadOnly;
region keyboard: region input [x: 256scancode, y: 1row, z: 1layer, t: 1frame] of U8x4
    @ ShortTerm @ ReadOnly;
region screen:  region graphics [x: 720px, y: 1440px, z: 1layer, t: 2frames] of U8x4
    @ ShortTerm @ ReadWrite;

process chat_screen:
    reads  touch, keyboard;
    private header_buf:   region graphics [x: 720px, y: 64px] of U8x4 @ ShortTerm
    private message_buf:  region graphics [x: 720px, y: 1312px] of U8x4 @ ShortTerm
    private input_buf:    region graphics [x: 720px, y: 64px] of U8x4 @ ShortTerm
    private messages:     region[len: 1MB] of Raw @ LongTerm
    private scroll_pos:   f32 = 0.0
    writes screen;

    when touch or keyboard changes:
        -- Spawn child processes for UI regions
        spawn header_bar with (reads: [keyboard], writes: [header_buf]);
        spawn message_list with (reads: [messages @ ReadOnly], writes: [message_buf]);
        spawn chat_input with (reads: [keyboard], writes: [input_buf, messages]);

        -- Handle scroll from touch
        if touch[x: *, y: *, z: 0, t: 0].active > 0.1:
            let delta = touch[x: *, y: *, z: 0, t: 0].pressure;
            scroll_pos := clamp(scroll_pos + delta, 0.0, messages.len as f32);
        end

        -- Render header with title
        fill header_buf with color #1A1A2E radius 0px;
        draw_text header_buf "Atom Chat" at (16px, 20px)
            font "Inter" size 18px color #FFFFFF bold;

        -- Render message list (virtual scroll)
        fill message_buf with color #0F0F1A;
        let start = floor(scroll_pos / 48px) as u32;
        let visible = ceil(1312px / 48px) as u32;
        for each i in start..min(start + visible, messages.count):
            let top = i * 48px - scroll_pos;
            draw_text message_buf messages[i].text at (16px, top)
                font "Inter" size 14px color #E0E0E0;
        end

        -- Render input bar
        fill input_buf with color #1A1A2E radius 12px;
        draw_text input_buf "Type a message..." at (16px, 20px)
            font "Inter" size 14px color #888888;

        -- Composite everything onto screen
        clear screen[t: current] to #0F0F1A;
        blend header_buf over screen[t: current] at (x: 0, y: 0);
        blend message_buf over screen[t: current] at (x: 0, y: 64px);
        blend input_buf over screen[t: current] at (x: 0, y: 1376px);

        -- Swap buffers
        swap screen[t: current] with screen[t: next];

    ensures:
        screen[t: current].a == 255 forall pixels;
        header_buf.dimensions == [x: 720px, y: 64px];
        message_buf.dimensions == [x: 720px, y: 1312px];
        input_buf.dimensions == [x: 720px, y: 64px];

    temporal invariant:
        always (not (screen.being_written and screen.being_scanned));
        always (touch.written ⇒ eventually screen.written);
end

-- Generative UI: card block from agent responses
region card_data: region[len: 512byte] of Raw @ ReadOnly;

process gen_card:
    reads  card_data;
    writes rendered: region graphics [x: 688px, y: auto px] of U8x4 @ ShortTerm @ ReadWrite;

    when card_data changes:
        let card = deserialize_card(card_data);

        fill rendered with color #FFFFFF radius 12px shadow 4px;
        draw_text rendered card.title at (16px, 16px)
            font "Inter" size 18px color #1A1A2E bold;
        draw_text rendered card.body at (16px, 48px)
            font "Inter" size 14px color #4A4A6A;

        if card.actions exists:
            let btn_y = rendered.height - 48px;
            fill rendered[x: 16px..672px, y: btn_y..btn_y+40px] with color #3B82F6 radius 8px;
            draw_text rendered card.actions[0].label at (center_x, btn_y + 12px)
                font "Inter" size 14px color #FFFFFF center;
        end

    ensures:
        rendered.width <= 688px;
end
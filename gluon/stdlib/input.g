-- Gluon Standard Library: Input
-- Keyboard, touch, and gesture processing on spatial regions.
-- Input regions use the F32x4 format with semantic context "input":
--   Touch: [active, pressure, contact_id, reserved]
--   Keyboard: [pressed, repeat_count, modifiers, reserved]

-- Decode raw scancode region into key events
process decode_scancodes:
    reads  keyboard: region input [x: 256 scancode, y: 1row, z: 1layer, t: 1frame] of U8x4 @ ReadOnly
    writes key_events: region[x: 16 event, y: 1, z: 1, t: 1] of U8x4 @ ShortTerm
    private event_count: region[x: 1, y: 1, z: 1, t: 1] of U8x4 @ ShortTerm

    when keyboard changes:
        let mut count = 0u8;
        for each sc in 0..256:
            let pressed = keyboard[x: sc, y: 0, z: 0, t: 0].pressed;
            let repeat = keyboard[x: sc, y: 0, z: 0, t: 0].repeat;
            if pressed > 0 or repeat > 0:
                if count < 16:
                    key_events[x: count as u32, y: 0, z: 0, t: 0] := [sc as u8, pressed, repeat, 0];
                    count := count + 1;
                end
            end
        end
        event_count[x: 0, y: 0, z: 0, t: 0] := [count, 0, 0, 0];
end

-- Parse touch input region into contact list
process parse_touch:
    reads  touch:    region input [x: W px, y: H px, z: 1layer, t: 1frame] of F32x4 @ ReadOnly
    writes contacts: region[x: 10 contact, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm
    private count:   region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm

    when touch changes:
        let mut n = 0u32;
        -- Scan touch region for active contacts
        -- This is simplified: real hardware provides per-contact data
        for each (x, y) in touch[x: 0..W:8, y: 0..H:8, z: 0, t: 0]:
            let active = touch[x: x, y: y, z: 0, t: 0].active;
            let pressure = touch[x: x, y: y, z: 0, t: 0].pressure;
            if active > 0.5 and n < 10:
                contacts[x: n, y: 0, z: 0, t: 0] := [x as f32, y as f32, pressure, active];
                n := n + 1;
            end
        end
        count[x: 0, y: 0, z: 0, t: 0] := [n as f32, 0, 0, 0];
end

-- Count the number of active touch contacts
process count_active_contacts:
    reads  touch: region input [x: W px, y: H px, z: 1layer, t: 1frame] of F32x4 @ ReadOnly
    writes result: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm

    when touch changes:
        let mut count = 0u32;
        for each (x, y) in touch[x: 0..W:4, y: 0..H:4, z: 0, t: 0]:
            if touch[x: x, y: y, z: 0, t: 0].active > 0.1:
                count := count + 1;
            end
        end
        result[x: 0, y: 0, z: 0, t: 0] := [count as f32, 0, 0, 0];
end

-- Compute velocity from touch history
process compute_velocity:
    reads  history: region[x: 16 frame, y: 1] of F32x4 @ ShortTerm @ ReadOnly
    writes velocity: region[x: 1, y: 1, z: 1, t: 1] of F32x4 @ ShortTerm

    when history changes:
        let x0 = history[x: 15, y: 0].c0;
        let y0 = history[x: 15, y: 0].c1;
        let x1 = history[x: 14, y: 0].c0;
        let y1 = history[x: 14, y: 0].c1;
        let vx = x0 - x1;
        let vy = y0 - y1;
        velocity[x: 0, y: 0, z: 0, t: 0] := [vx, vy, sqrt(vx * vx + vy * vy), 0];
end

-- Recognize gestures from touch input and history
process gesture_recognizer:
    reads  touch: region input [x: W px, y: H px] of F32x4 @ ReadOnly
    reads  history: region[x: 16 frame, y: 1] of F32x4 @ ShortTerm @ ReadOnly
    writes gesture: region[x: 1, y: 1] of F32x4 @ ShortTerm
    -- gesture format: [type_id, data0, data1, data2]
    -- type_id: 0=none, 1=tap, 2=swipe, 3=pinch, 4=long_press

    when touch changes:
        let contacts = count_active_contacts(touch);
        if contacts == 1:
            let vel = compute_velocity(history);
            let speed = vel[x: 0, y: 0, z: 0, t: 0].c2;
            if speed > 500.0:
                let dx = vel[x: 0, y: 0, z: 0, t: 0].c0;
                let dy = vel[x: 0, y: 0, z: 0, t: 0].c1;
                gesture[x: 0, y: 0] := [2.0, dx, dy, speed];
            else:
                let hold_time = history[x: 0, y: 0, z: 0, t: 0].c2;
                if hold_time > 33.0:
                    gesture[x: 0, y: 0] := [4.0, hold_time, 0, 0];
                else:
                    gesture[x: 0, y: 0] := [1.0, 0, 0, 0];
                end
            end
        else if contacts == 2:
            gesture[x: 0, y: 0] := [3.0, 0, 0, 0];
        else:
            gesture[x: 0, y: 0] := [0.0, 0, 0, 0];
        end
end
-- Triangle Renderer: 3D graphics with matrix projection
-- Demonstrates: Spatial regions, U8x4 format, project, blend, matrix math

region framebuffer: region graphics [x: 720px, y: 1440px, z: 1layer, t: 2frames] of U8x4
    @ ShortTerm @ ReadWrite;
region camera_matrix: region[x: 1, y: 1, z: 1, t: 1] of F32x4
    @ ShortTerm @ ReadWrite;
region triangle: region graphics [x: 3vertex, y: 1, z: 1, t: 1] of F32x4
    @ ShortTerm @ ReadOnly;

process triangle_renderer:
    reads  triangle, camera_matrix;
    writes framebuffer;

    when triangle or camera_matrix changes:
        clear framebuffer[t: current] to #1E1E2E;
        project triangle through camera_matrix onto framebuffer[t: current];

    ensures:
        framebuffer[t: current].dimensions == [x: 720px, y: 1440px, z: 1layer, t: 1frame];
        framebuffer[t: current].a == 255 forall pixels;
end

-- Full scene compositor: background + 3D scene + UI overlay
region scene_bg: region graphics [x: 720px, y: 1440px, z: 1layer, t: 1frame] of U8x4
    @ ShortTerm;
region ui_overlay: region graphics [x: 720px, y: 1440px, z: 1layer, t: 1frame] of U8x4
    @ ShortTerm;

process scene_compositor:
    reads  camera_matrix, triangle;
    writes framebuffer, scene_bg, ui_overlay;

    when camera_matrix or triangle changes:
        -- Render 3D scene into background
        clear scene_bg to #27293A;
        project triangle through camera_matrix onto scene_bg;

        -- Draw UI overlay
        fill ui_overlay with color #00000000;
        draw_text ui_overlay "Atom OS" at (16px, 32px) font "Inter" size 24px color #FFFFFF bold;

        -- Compose layers
        blend scene_bg over framebuffer[t: current];
        blend ui_overlay over framebuffer[t: current];

        -- Double-buffer swap
        swap framebuffer[t: current] with framebuffer[t: next];

    ensures:
        framebuffer[t: scanned].a == 255 forall pixels;
        not (framebuffer.being_written and framebuffer.being_scanned);

    temporal invariant:
        always (camera_matrix.written ⇒ eventually framebuffer.written);
        always (not (framebuffer.being_written and framebuffer.being_scanned));
end
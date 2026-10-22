-- CRT Shader module for Starflight LÖVE
-- Implements curved screen (barrel distortion), scanlines, vignette, and random glitches.

local crt = {}
local shader = nil
local canvas = nil

-- Bezel padding inside the 640x480 CRT canvas:
-- Gives room for the barrel curvature to curve gracefully without cutting off any UI.
-- Aspect ratio: (640 - 2*20) / (480 - 2*15) = 600 / 450 = 4 / 3.
local PAD_X, PAD_Y = 20, 15
local GW, GH = 640 - 2 * PAD_X, 480 - 2 * PAD_Y

local shader_code = [[
extern number time;
extern number enable_glitch;

float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords) {
    // 1. Curved Screen (CRT barrel distortion)
    vec2 cc = (texture_coords - 0.5) * 2.0;
    float r2 = dot(cc, cc);
    // Authentic CRT glass curvature (barrel bend):
    vec2 curved_cc = cc * (0.94 + 0.05 * r2);
    vec2 uv = (curved_cc + 1.0) * 0.5;

    // Out-of-bounds check (outside CRT tube face)
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return vec4(0.015, 0.015, 0.02, 1.0);
    }

    // 2. Random Glitches (horizontal jitter, chromatic aberration burst, noise)
    float glitch_disp = 0.0;
    float glitch_noise = 0.0;
    float rgb_split = 0.0010; // subtle base chromatic separation

    if (enable_glitch > 0.5) {
        float glitch_step = floor(time * 3.5);
        float glitch_seed = hash(vec2(glitch_step, 23.41));
        bool is_glitch = glitch_seed > 0.80; // ~20% of intervals trigger a glitch

        if (is_glitch) {
            // Primary horizontal tear band
            float band_y = hash(vec2(glitch_step, 4.7));
            float band_h = 0.03 + hash(vec2(glitch_step, 8.2)) * 0.12;
            if (uv.y >= band_y && uv.y <= band_y + band_h) {
                glitch_disp = (hash(vec2(glitch_step, 14.1)) - 0.5) * 0.035;
            }
            // Secondary smaller twitch band
            float band_y2 = hash(vec2(glitch_step, 31.9));
            float band_h2 = 0.015 + hash(vec2(glitch_step, 19.3)) * 0.05;
            if (uv.y >= band_y2 && uv.y <= band_y2 + band_h2) {
                glitch_disp += (hash(vec2(glitch_step, 27.6)) - 0.5) * 0.020;
            }
            // Chromatic split amplifies during glitch
            rgb_split += 0.004 * hash(vec2(glitch_step, 6.3));
            // Static noise burst
            glitch_noise = (hash(vec2(uv.y * 350.0, fract(time * 29.0))) - 0.5) * 0.07;
        }
    }

    vec2 sample_uv = uv;
    sample_uv.x = clamp(sample_uv.x + glitch_disp, 0.0, 1.0);

    // Sample texture with chromatic aberration (RGB separation)
    vec4 col;
    col.r = Texel(tex, clamp(vec2(sample_uv.x + rgb_split, sample_uv.y), 0.0, 1.0)).r;
    col.g = Texel(tex, sample_uv).g;
    col.b = Texel(tex, clamp(vec2(sample_uv.x - rgb_split, sample_uv.y), 0.0, 1.0)).b;
    col.a = 1.0;

    // Add glitch noise
    col.rgb += vec3(glitch_noise);

    // 3. Scan lines (~240 CRT scanlines across the tube)
    float scan = sin(texture_coords.y * 240.0 * 3.14159265 * 2.0);
    float scan_weight = 1.0 - 0.15 * (scan * scan);
    col.rgb *= scan_weight;

    // Subtle phosphor triad mask
    float triad = mod(screen_coords.x, 3.0);
    vec3 triad_mask = vec3(0.96);
    if (triad < 1.0) {
        triad_mask.r = 1.04;
    } else if (triad < 2.0) {
        triad_mask.g = 1.04;
    } else {
        triad_mask.b = 1.04;
    }
    col.rgb *= triad_mask;

    // 4. Subtle Vignette effect across the monitor tube
    vec2 tc_c = (texture_coords - 0.5) * 2.0;
    float tc_r2 = dot(tc_c, tc_c);
    float vignette = clamp(1.0 - 0.18 * tc_r2, 0.82, 1.0);
    col.rgb *= vignette;

    // Brightness compensation for scanline absorption
    col.rgb *= 1.06;

    return col * color;
}
]]

function crt.init()
    if not shader then
        local ok, s = pcall(love.graphics.newShader, shader_code)
        if ok then
            shader = s
        else
            print("CRT Shader compilation failed:", s)
            shader = nil
        end
    end
end

function crt.render(image, quad, w, h, x, y, dw, dh, time, glitch)
    if not shader then crt.init() end
    if not shader then
        love.graphics.setColor(1, 1, 1)
        if quad then
            love.graphics.draw(image, quad, x, y, 0, dw / w, dh / h)
        else
            love.graphics.draw(image, x, y, 0, dw / w, dh / h)
        end
        return
    end

    if not canvas then
        canvas = love.graphics.newCanvas(640, 480)
        canvas:setFilter("linear", "linear")
    end

    local prev_canvas = love.graphics.getCanvas()
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0.015, 0.015, 0.02, 1.0)
    love.graphics.setColor(1, 1, 1)
    if quad then
        love.graphics.draw(image, quad, PAD_X, PAD_Y, 0, GW / w, GH / h)
    else
        love.graphics.draw(image, PAD_X, PAD_Y, 0, GW / w, GH / h)
    end
    love.graphics.setCanvas(prev_canvas)

    love.graphics.setShader(shader)
    shader:send("time", time)
    shader:send("enable_glitch", (glitch == nil or glitch) and 1.0 or 0.0)
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(canvas, x, y, 0, dw / 640, dh / 480)
    love.graphics.setShader()
end

-- Screen-space monitor coordinates (u, v in 0..1) to game coordinates (vx 0..319, vy 0..199)
function crt.to_game(u, v)
    local cx = (u - 0.5) * 2.0
    local cy = (v - 0.5) * 2.0
    local r2 = cx * cx + cy * cy
    local scale = 0.94 + 0.05 * r2
    cx = cx * scale
    cy = cy * scale
    local uv_x = (cx + 1.0) * 0.5
    local uv_y = (cy + 1.0) * 0.5
    if uv_x < 0.0 or uv_x > 1.0 or uv_y < 0.0 or uv_y > 1.0 then return nil, nil end
    local canv_x = uv_x * 640.0
    local canv_y = uv_y * 480.0
    local vx = (canv_x - PAD_X) / GW * 320.0
    local vy = (canv_y - PAD_Y) / GH * 200.0
    if vx < 0 or vx >= 320 or vy < 0 or vy >= 200 then return nil, nil end
    return vx, vy
end

return crt

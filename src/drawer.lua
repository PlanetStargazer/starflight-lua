-- Quick Access Floating Menu & In-Game Modals (Help, Settings, Log, Main Menu)
-- Styled using Starflight's authentic EGA bitmap font (gamefont)
local M = {}
local gamefont = require("gamefont")

local slide = 0.0           -- 0.0 = hidden, 1.0 = fully open
local hovered = false
local btn_hover = nil
local help_open = false
local settings_open = false

local PANEL_W = 180
local PANEL_H = 240
local BTN_H = 38
local BTN_GAP = 8

local callbacks = {}

function M.init(cb)
    callbacks = cb or {}
    pcall(gamefont.build)
end

function M.is_open()
    if callbacks.is_in_game and not callbacks.is_in_game() then
        return false
    end
    return slide > 0.1 or help_open or settings_open
end

function M.close_modals()
    help_open = false
    settings_open = false
end

local function ensure_font()
    if not gamefont.small or not gamefont.small.image or (gamefont.small.w[65] or 0) == 0 then
        pcall(gamefont.build)
    end
end

-- Draw text using gamefont at an integer or floating scale
local function draw_text(f, text, x, y, scale)
    scale = scale or 2
    ensure_font()
    f = f or gamefont.small
    if not f or not f.image then
        love.graphics.print(text, x, y)
        return #text * 8
    end
    local cx = x
    local first, last = f.first, f.last
    local img = f.image
    local quads = f.quad
    local widths = f.w
    for i = 1, #text do
        local c = text:byte(i)
        if c >= 97 and c <= 122 then c = c - 32 end -- lowercase -> uppercase
        if c >= first and c <= last and quads[c] then
            love.graphics.draw(img, quads[c], cx, y, 0, scale, scale)
            cx = cx + (widths[c] + 1) * scale
        else
            cx = cx + ((widths[0x20] or 3) + 1) * scale
        end
    end
    return cx - x
end

local function text_width(f, text, scale)
    scale = scale or 2
    ensure_font()
    f = f or gamefont.small
    if not f or not f.w then return #text * 6 * scale end
    return gamefont.width(f, text) * scale
end

function M.update(dt)
    if callbacks.is_in_game and not callbacks.is_in_game() then
        slide = 0.0
        hovered = false
        btn_hover = nil
        help_open = false
        settings_open = false
        return
    end

    ensure_font()

    local W, H = love.graphics.getDimensions()
    local mx, my = love.mouse.getPosition()
    local py = math.floor((H - PANEL_H) / 2)

    -- Trigger zone: mouse near left edge (<= 20px), or mouse over panel while open
    if mx <= 20 and my >= py - 40 and my <= py + PANEL_H + 40 then
        hovered = true
    elseif slide > 0.05 and mx <= PANEL_W + 25 and my >= py - 20 and my <= py + PANEL_H + 20 then
        hovered = true
    else
        hovered = false
    end

    local target = (hovered and not (help_open or settings_open)) and 1.0 or 0.0
    slide = slide + (target - slide) * math.min(1.0, dt * 10.0)

    -- Track button hover
    btn_hover = nil
    if slide > 0.5 and not (help_open or settings_open) then
        local px = (slide - 1.0) * PANEL_W
        local by0 = py + 40
        for i = 1, 4 do
            local by = by0 + (i - 1) * (BTN_H + BTN_GAP)
            if mx >= px + 10 and mx <= px + PANEL_W - 10 and my >= by and my <= by + BTN_H then
                btn_hover = i
                break
            end
        end
    end
end

-- Draw gear icon for Settings
local function draw_gear_icon(cx, cy, r, col, bg)
    love.graphics.setColor(col)
    love.graphics.circle("fill", cx, cy, r)
    for i = 0, 7 do
        local a = i * (math.pi / 4)
        local tx = cx + math.cos(a) * (r + 2)
        local ty = cy + math.sin(a) * (r + 2)
        love.graphics.circle("fill", tx, ty, 2)
    end
    love.graphics.setColor(bg)
    love.graphics.circle("fill", cx, cy, r * 0.42)
end

-- Draw document / log icon
local function draw_log_icon(cx, cy, col, bg)
    love.graphics.setColor(col)
    love.graphics.rectangle("fill", cx - 7, cy - 8, 14, 16, 2, 2)
    love.graphics.setColor(bg)
    love.graphics.line(cx - 4, cy - 4, cx + 4, cy - 4)
    love.graphics.line(cx - 4, cy, cx + 4, cy)
    love.graphics.line(cx - 4, cy + 4, cx + 1, cy + 4)
end

-- Draw help icon
local function draw_help_icon(cx, cy, r, col, bg)
    love.graphics.setColor(col)
    love.graphics.setLineWidth(1.5)
    love.graphics.circle("line", cx, cy, r)
    draw_text(gamefont.small, "?", cx - 3, cy - 6, 1.8)
end

-- Draw main menu / home icon
local function draw_menu_icon(cx, cy, col)
    love.graphics.setColor(col)
    love.graphics.setLineWidth(1.8)
    -- House / home outline
    love.graphics.polygon("line", cx - 7, cy - 1, cx, cy - 8, cx + 7, cy - 1)
    love.graphics.rectangle("line", cx - 5, cy - 1, 10, 8)
end

function M.draw(W, H)
    if callbacks.is_in_game and not callbacks.is_in_game() then
        return
    end

    -- 1. Draw Slide-Out Drawer
    if slide > 0.01 then
        local px = (slide - 1.0) * PANEL_W
        local py = math.floor((H - PANEL_H) / 2)

        -- Background shadow
        love.graphics.setColor(0, 0, 0, 0.6 * slide)
        love.graphics.rectangle("fill", px + 4, py + 4, PANEL_W, PANEL_H, 6, 6)

        -- Panel background (dark navy glass)
        love.graphics.setColor(0.04, 0.07, 0.14, 0.95)
        love.graphics.rectangle("fill", px, py, PANEL_W, PANEL_H, 6, 6)

        -- Panel border (cyan EGA theme)
        love.graphics.setColor(0, 0.75, 0.85, 0.95)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", px + 1, py + 1, PANEL_W - 2, PANEL_H - 2, 6, 6)

        -- Header
        love.graphics.setColor(0.2, 0.9, 1.0)
        local qm_title = "QUICK MENU"
        local qm_w = text_width(gamefont.large or gamefont.small, qm_title, 2)
        draw_text(gamefont.large or gamefont.small, qm_title, px + (PANEL_W - qm_w) / 2, py + 12, 2)
        love.graphics.setColor(0, 0.5, 0.6, 0.7)
        love.graphics.line(px + 12, py + 30, px + PANEL_W - 12, py + 30)

        -- Buttons
        local buttons = {
            {id = 1, text = "QUEST LOG", icon = "log"},
            {id = 2, text = "SETTINGS", icon = "gear"},
            {id = 3, text = "HELP", icon = "help"},
            {id = 4, text = "MAIN MENU", icon = "menu"},
        }

        local by0 = py + 40
        for i, btn in ipairs(buttons) do
            local by = by0 + (i - 1) * (BTN_H + BTN_GAP)
            local bx = px + 10
            local bw = PANEL_W - 20
            local is_h = (btn_hover == i)

            -- Button Background
            if is_h then
                love.graphics.setColor(0.12, 0.28, 0.44, 0.95)
            else
                love.graphics.setColor(0.06, 0.12, 0.22, 0.85)
            end
            love.graphics.rectangle("fill", bx, by, bw, BTN_H, 4, 4)

            -- Button Border
            if is_h then
                love.graphics.setColor(0.4, 0.95, 1.0, 1.0)
                love.graphics.setLineWidth(1.5)
            else
                love.graphics.setColor(0, 0.55, 0.65, 0.75)
                love.graphics.setLineWidth(1)
            end
            love.graphics.rectangle("line", bx, by, bw, BTN_H, 4, 4)

            -- Icon
            local bg_c = is_h and {0.12, 0.28, 0.44} or {0.06, 0.12, 0.22}
            local fg_c = is_h and {1, 1, 1} or {0, 0.85, 0.95}
            local icx, icy = bx + 18, by + BTN_H / 2

            if btn.icon == "log" then
                draw_log_icon(icx, icy, fg_c, bg_c)
            elseif btn.icon == "gear" then
                draw_gear_icon(icx, icy, 6, fg_c, bg_c)
            elseif btn.icon == "help" then
                draw_help_icon(icx, icy, 8, fg_c, bg_c)
            elseif btn.icon == "menu" then
                draw_menu_icon(icx, icy, fg_c)
            end

            -- Label in gamefont
            if is_h then
                love.graphics.setColor(1, 1, 1)
            else
                love.graphics.setColor(0.85, 0.95, 1.0)
            end
            draw_text(gamefont.small, btn.text, bx + 36, by + 12, 2)
        end
    end

    -- 2. Indicator Tab when closed or closing
    if slide < 0.85 and not (help_open or settings_open) then
        local py = math.floor((H - PANEL_H) / 2)
        local tab_h = 44
        local tab_y = py + (PANEL_H - tab_h) / 2
        local tab_w = 6

        love.graphics.setColor(0, 0.75, 0.9, 0.4 + 0.4 * (1.0 - slide))
        love.graphics.rectangle("fill", 0, tab_y, tab_w, tab_h, 0, 3)
    end

    -- 3. In-Game Settings Modal
    if settings_open then
        M.draw_settings_modal(W, H)
    end

    -- 4. Help / Controls Modal
    if help_open then
        M.draw_help_modal(W, H)
    end
end

function M.draw_settings_modal(W, H)
    local mw = 480
    local mh = 500
    local mx = math.floor((W - mw) / 2)
    local my = math.floor((H - mh) / 2)

    -- Dim background
    love.graphics.setColor(0, 0, 0, 0.78)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- Window body
    love.graphics.setColor(0.04, 0.06, 0.12, 0.97)
    love.graphics.rectangle("fill", mx, my, mw, mh, 8, 8)
    love.graphics.setColor(0, 0.75, 0.85, 0.95)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", mx, my, mw, mh, 8, 8)

    -- Title
    love.graphics.setColor(0.2, 0.9, 1.0)
    local title = "SETTINGS"
    local tw = text_width(gamefont.large or gamefont.small, title, 2)
    draw_text(gamefont.large or gamefont.small, title, mx + (mw - tw) / 2, my + 14, 2)
    love.graphics.setColor(0, 0.5, 0.6, 0.7)
    love.graphics.line(mx + 20, my + 38, mx + mw - 20, my + 38)

    -- Close Button [X]
    love.graphics.setColor(0.8, 0.2, 0.2, 0.8)
    love.graphics.rectangle("fill", mx + mw - 34, my + 10, 22, 22, 3, 3)
    love.graphics.setColor(1, 1, 1)
    draw_text(gamefont.small, "X", mx + mw - 26, my + 14, 2)

    -- Settings items list
    local st_list = callbacks.SETTINGS or {}
    local curr_st = callbacks.settings or {}
    local sy0 = my + 48
    local row_h = 30
    local mouse_x, mouse_y = love.mouse.getPosition()

    for i, st in ipairs(st_list) do
        local ry = sy0 + (i - 1) * row_h
        local is_hover = (mouse_x >= mx + 20 and mouse_x <= mx + mw - 20 and mouse_y >= ry and mouse_y <= ry + row_h - 2)

        if is_hover then
            love.graphics.setColor(0.1, 0.2, 0.35, 0.6)
            love.graphics.rectangle("fill", mx + 20, ry, mw - 40, row_h - 2, 4, 4)
        end

        -- Label in gamefont
        love.graphics.setColor(is_hover and {1, 1, 1} or {0.8, 0.9, 1.0})
        draw_text(gamefont.small, st[2], mx + 30, ry + 8, 2)

        -- Toggle Button
        local on = curr_st[st[1]]
        local pill_w, pill_h = 56, 22
        local tx = mx + mw - 30 - pill_w
        local ty = ry + 4

        if on then
            love.graphics.setColor(0, 0.65, 0.45, 0.9)
            love.graphics.rectangle("fill", tx, ty, pill_w, pill_h, 4, 4)
            love.graphics.setColor(1, 1, 1)
            local on_w = text_width(gamefont.small, "ON", 2)
            draw_text(gamefont.small, "ON", tx + (pill_w - on_w) / 2, ty + 4, 2)
        else
            love.graphics.setColor(0.2, 0.25, 0.32, 0.85)
            love.graphics.rectangle("fill", tx, ty, pill_w, pill_h, 4, 4)
            love.graphics.setColor(0.65, 0.7, 0.75)
            local off_w = text_width(gamefont.small, "OFF", 2)
            draw_text(gamefont.small, "OFF", tx + (pill_w - off_w) / 2, ty + 4, 2)
        end
    end

    -- Close Button at bottom
    local btn_y = my + mh - 44
    local is_btn_h = (mouse_x >= mx + mw / 2 - 60 and mouse_x <= mx + mw / 2 + 60 and mouse_y >= btn_y and mouse_y <= btn_y + 28)
    love.graphics.setColor(is_btn_h and {0.15, 0.35, 0.55} or {0.08, 0.16, 0.28})
    love.graphics.rectangle("fill", mx + mw / 2 - 60, btn_y, 120, 28, 4, 4)
    love.graphics.setColor(0, 0.75, 0.85)
    love.graphics.rectangle("line", mx + mw / 2 - 60, btn_y, 120, 28, 4, 4)
    love.graphics.setColor(1, 1, 1)
    local cl_w = text_width(gamefont.small, "CLOSE", 2)
    draw_text(gamefont.small, "CLOSE", mx + (mw - cl_w) / 2, btn_y + 7, 2)
end

function M.draw_help_modal(W, H)
    local mw = 860
    local mh = 510
    local mx = math.floor((W - mw) / 2)
    local my = math.floor((H - mh) / 2)

    -- Dim background
    love.graphics.setColor(0, 0, 0, 0.78)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- Window body
    love.graphics.setColor(0.04, 0.06, 0.12, 0.97)
    love.graphics.rectangle("fill", mx, my, mw, mh, 8, 8)
    love.graphics.setColor(0, 0.75, 0.85, 0.95)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", mx, my, mw, mh, 8, 8)

    -- Title
    love.graphics.setColor(0.2, 0.9, 1.0)
    local title = "STARFLIGHT CONTROLS AND COMMANDS"
    local tw = text_width(gamefont.large or gamefont.small, title, 2)
    draw_text(gamefont.large or gamefont.small, title, mx + (mw - tw) / 2, my + 14, 2)
    love.graphics.setColor(0, 0.5, 0.6, 0.7)
    love.graphics.line(mx + 20, my + 38, mx + mw - 20, my + 38)

    -- Close Button [X]
    love.graphics.setColor(0.8, 0.2, 0.2, 0.8)
    love.graphics.rectangle("fill", mx + mw - 34, my + 10, 22, 22, 3, 3)
    love.graphics.setColor(1, 1, 1)
    draw_text(gamefont.small, "X", mx + mw - 26, my + 14, 2)

    -- Columns
    local col_w = (mw - 60) / 2
    local c1_x = mx + 20
    local c2_x = mx + 40 + col_w
    local cur_y = my + 46
    local is_debug = callbacks.settings and callbacks.settings.debug

    local function draw_section(cx, cy, header, items, header_col)
        local hcol = header_col or {0, 0.85, 0.95}
        love.graphics.setColor(hcol)
        draw_text(gamefont.large or gamefont.small, header, cx, cy, 1.8)
        love.graphics.setColor(hcol[1] * 0.6, hcol[2] * 0.6, hcol[3] * 0.6, 0.7)
        love.graphics.line(cx, cy + 18, cx + col_w, cy + 18)

        local y = cy + 24
        for _, it in ipairs(items) do
            love.graphics.setColor(0.95, 0.85, 0.3)
            draw_text(gamefont.small, it[1], cx + 4, y, 1.6)
            love.graphics.setColor(0.85, 0.9, 0.95)
            draw_text(gamefont.small, it[2], cx + 160, y, 1.6)
            y = y + 18
        end
        return y + 8
    end

    -- Left Column
    local y1 = draw_section(c1_x, cur_y, "NAVIGATION AND ACTIONS", {
        {"ARROW / NUMPAD", "MOVE SHIP, CURSOR AND VEHICLE"},
        {"SPACE / RETURN", "SELECT HIGHLIGHTED OPTION"},
        {"ESC", "CANCEL / IN-GAME SAVE MENU"},
    })

    y1 = draw_section(c1_x, y1, "MOUSE CONTROLS", {
        {"LEFT CLICK", "CLICK BUTTONS AND WALK TARGET"},
        {"RIGHT CLICK", "BACK / CANCEL / RESUME GAME"},
        {"MOUSE WHEEL", "SCROLL QUEST LOG AND MENUS"},
        {"LEFT BORDER", "HOVER TO OPEN QUICK MENU"},
    })

    y1 = draw_section(c1_x, y1, "SPEED AND SIMULATION", {
        {"CTRL-LEFT", "HALVE SIMULATION SPEED"},
        {"CTRL-RIGHT", "DOUBLE SIMULATION SPEED"},
        {"CTRL-DOWN", "UNLIMITED SPEED - MAX"},
    })

    if is_debug then
        y1 = draw_section(c1_x, y1, "SHIP STATIONS", {
            {"1 .. 8", "DIRECT SHIP COMMAND KEYS"},
            {"LEFT / RIGHT", "SELECT STARPORT BUTTONS"},
            {"UP / DOWN", "SELECT STATION ACTION LIST"},
        })
    end

    -- Right Column
    local y2 = draw_section(c2_x, cur_y, "SHORTCUTS AND FEATURES", {
        {"CTRL-L", "QUEST LOG - NOTICES AND INTEL"},
        {"CTRL-G", "TOGGLE CRT RANDOM GLITCHES"},
        {"CTRL-Q", "RETURN TO SAVE SLOT MENU"},
        {"ALT-ENTER", "TOGGLE FULLSCREEN"},
    })

    if not is_debug then
        y2 = draw_section(c2_x, y2, "SHIP STATIONS", {
            {"1 .. 8", "DIRECT SHIP COMMAND KEYS"},
            {"LEFT / RIGHT", "SELECT STARPORT BUTTONS"},
            {"UP / DOWN", "SELECT STATION ACTION LIST"},
        })
    else
        y2 = draw_section(c2_x, y2, "DEBUG KEYS - F3-F11", {
            {"F3 / G", "TOGGLE CRT RANDOM GLITCHES"},
            {"F4", "TOGGLE CRT CURVED SHADER"},
            {"F5", "QUEST LOG - NOTICES AND INTEL"},
            {"F6", "TOGGLE INTERFACE SOUNDS"},
            {"F7", "TOGGLE SHORT DELAYS / WAITS"},
            {"F8", "TOGGLE ENHANCED AUDIO SYNTH"},
            {"F9", "CHEAT: MAX CREW AND SHIP"},
            {"F10", "RETURN TO SAVE SLOT MENU"},
            {"F11", "TOGGLE FULLSCREEN"},
        }, {1.0, 0.55, 0.2})
    end

    -- Footer Close button
    local mouse_x, mouse_y = love.mouse.getPosition()
    local btn_y = my + mh - 38
    local is_btn_h = (mouse_x >= mx + mw / 2 - 75 and mouse_x <= mx + mw / 2 + 75 and mouse_y >= btn_y and mouse_y <= btn_y + 26)
    love.graphics.setColor(is_btn_h and {0.15, 0.35, 0.55} or {0.08, 0.16, 0.28})
    love.graphics.rectangle("fill", mx + mw / 2 - 75, btn_y, 150, 26, 4, 4)
    love.graphics.setColor(0, 0.75, 0.85)
    love.graphics.rectangle("line", mx + mw / 2 - 75, btn_y, 150, 26, 4, 4)
    love.graphics.setColor(1, 1, 1)
    local cl_w = text_width(gamefont.small, "CLOSE - ESC", 1.8)
    draw_text(gamefont.small, "CLOSE - ESC", mx + (mw - cl_w) / 2, btn_y + 5, 1.8)
end

function M.mousepressed(x, y, button)
    if callbacks.is_in_game and not callbacks.is_in_game() then
        return false
    end

    local W, H = love.graphics.getDimensions()

    -- 1. Help Modal Active
    if help_open then
        local mw, mh = 860, 510
        local mx = math.floor((W - mw) / 2)
        local my = math.floor((H - mh) / 2)

        -- Top right close [X]
        if x >= mx + mw - 34 and x <= mx + mw - 12 and y >= my + 10 and y <= my + 32 then
            help_open = false
            if callbacks.synth and callbacks.synth.blip then callbacks.synth.blip("back") end
            return true
        end

        -- Bottom close button
        local btn_y = my + mh - 38
        if x >= mx + mw / 2 - 75 and x <= mx + mw / 2 + 75 and y >= btn_y and y <= btn_y + 26 then
            help_open = false
            if callbacks.synth and callbacks.synth.blip then callbacks.synth.blip("back") end
            return true
        end

        -- Click outside modal closes it
        if x < mx or x > mx + mw or y < my or y > my + mh then
            help_open = false
            return true
        end
        return true
    end

    -- 2. Settings Modal Active
    if settings_open then
        local mw, mh = 480, 500
        local mx = math.floor((W - mw) / 2)
        local my = math.floor((H - mh) / 2)

        -- Top right close [X]
        if x >= mx + mw - 34 and x <= mx + mw - 12 and y >= my + 10 and y <= my + 32 then
            settings_open = false
            if callbacks.synth and callbacks.synth.blip then callbacks.synth.blip("back") end
            return true
        end

        -- Bottom close button
        local btn_y = my + mh - 44
        if x >= mx + mw / 2 - 60 and x <= mx + mw / 2 + 60 and y >= btn_y and y <= btn_y + 28 then
            settings_open = false
            if callbacks.synth and callbacks.synth.blip then callbacks.synth.blip("back") end
            return true
        end

        -- Click on settings rows
        local st_list = callbacks.SETTINGS or {}
        local curr_st = callbacks.settings or {}
        local sy0 = my + 48
        local row_h = 30
        for i, st in ipairs(st_list) do
            local ry = sy0 + (i - 1) * row_h
            if x >= mx + 20 and x <= mx + mw - 20 and y >= ry and y <= ry + row_h - 2 then
                curr_st[st[1]] = not curr_st[st[1]]
                if callbacks.settings_save then callbacks.settings_save() end
                if callbacks.synth and callbacks.synth.blip then callbacks.synth.blip("ok") end
                return true
            end
        end

        -- Click outside modal closes it
        if x < mx or x > mx + mw or y < my or y > my + mh then
            settings_open = false
            return true
        end
        return true
    end

    -- 3. Drawer Active
    if slide > 0.4 then
        local px = (slide - 1.0) * PANEL_W
        local py = math.floor((H - PANEL_H) / 2)
        local by0 = py + 40

        if x >= px and x <= px + PANEL_W and y >= py and y <= py + PANEL_H then
            for i = 1, 4 do
                local by = by0 + (i - 1) * (BTN_H + BTN_GAP)
                if x >= px + 10 and x <= px + PANEL_W - 10 and y >= by and y <= by + BTN_H then
                    if callbacks.synth and callbacks.synth.blip then callbacks.synth.blip("ok") end
                    if i == 1 then
                        -- QUEST LOG: Close drawer and toggle log
                        slide = 0.0
                        hovered = false
                        M.close_modals()
                        if callbacks.toggle_log then callbacks.toggle_log() end
                    elseif i == 2 then
                        -- SETTINGS
                        settings_open = true
                    elseif i == 3 then
                        -- HELP
                        help_open = true
                    elseif i == 4 then
                        -- MAIN MENU: Close drawer and return to slot menu
                        slide = 0.0
                        hovered = false
                        M.close_modals()
                        if callbacks.go_menu then callbacks.go_menu() end
                    end
                    return true
                end
            end
            return true   -- consumed by panel
        end
    end

    return false
end

function M.keypressed(key)
    if callbacks.is_in_game and not callbacks.is_in_game() then
        return false
    end

    if help_open then
        if key == "escape" or key == "space" or key == "return" then
            help_open = false
            return true
        end
        return true
    end
    if settings_open then
        if key == "escape" then
            settings_open = false
            return true
        end
        return true
    end
    return false
end

return M

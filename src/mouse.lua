-- Mouse support: the game only knows the keyboard, so a click is turned into the arrow keys and the
-- Space bar that would have reached the same button.  Two kinds of button are recognised, both from the
-- text the game draws ({GTYPE}, reported through M.note):
--   * a button bar along the bottom (Operations, Personnel, Ship Configuration, the terrain vehicle...):
--     its labels are typed left to right on one row; the highlighted button is the one whose background
--     differs from the others, and Left/Right moves the highlight
--   * the command list of the ship (up to 8 buttons in a column at x = 93, 11 pixels apart, highlight
--     index in THIS-BUTTON); Up/Down moves the highlight
-- Coordinates here are game pixels: x 0..159, y 0..199 counted from the bottom, as the game uses them.
local M = {}

local KEY = {up = 0x4800, down = 0x5000, left = 0x4B00, right = 0x4D00, space = 32, enter = 13}
local LIST_X, LIST_Y0, LIST_STEP = 93, 119, 11
local BAR_TOP = 12                                   -- text typed at or below this row belongs to a bar
local CHAR_W = 3                                     -- average width of a character of the small font

local bar, list, last_ov = {}, {}, nil
local save_menu = false

function M.reset() bar, list = {}, {}; save_menu = false end

-- every string the game draws, with the position it is drawn at
function M.note(str, x, y, ov)
    if ov ~= last_ov then bar, list = {}, {}; save_menu = false; last_ov = ov end   -- a new screen
    if ov == 0x8F71 and (str:find("SAVE GAME") or str:find("SELECT AN OPTION") or str:find("GAME OPTIONS")) then
        save_menu = true
    elseif ov ~= 0x8F71 or str:find("RESUMING") then
        save_menu = false
    end
    if y >= 2 and y <= BAR_TOP and #str > 1 then
        if #bar > 0 and x <= bar[#bar].x then bar = {} end        -- a bar is typed left to right: this one is new
        bar[#bar + 1] = {s = str, x = x, y = y}
    end
    if x == LIST_X and (LIST_Y0 - y) % LIST_STEP == 0 then
        local i = (LIST_Y0 - y) / LIST_STEP
        if i >= 0 and i <= 7 then
            if i == 0 then list = {} end
            list[i] = str
        end
    end
end

local function repeated(key, n, out) for _ = 1, n do out[#out + 1] = KEY[key] end end

-- bar button under x, or nil
local function bar_index(gx)
    local n = #bar
    for i = 1, n do
        local limit = 160
        if i < n then limit = (bar[i].x + CHAR_W * #bar[i].s + bar[i + 1].x) / 2 end
        if gx < limit then return i end
    end
end

-- Which bar button is highlighted: the one with a background colour of its own.
local NORMAL = {["0,0,0"] = true, ["85,85,255"] = true, ["0,0,170"] = true}
local function bar_current(probe)
    local colours, count = {}, {}
    for i, l in ipairs(bar) do
        local c = probe(l.x - 1, 4)
        colours[i] = c
        count[c] = (count[c] or 0) + 1
    end
    local found
    for i, c in ipairs(colours) do
        local odd = count[c] == 1 and #bar >= 3 or (#bar == 2 and not NORMAL[c])
        if odd then
            if found then return nil end             -- no single highlight
            found = i
        end
    end
    return found
end

-- Keys that press the bar button at (gx, gy), or nil when the click is not on a bar.
function M.click_bar(gx, gy, probe)
    if gy > BAR_TOP + 2 or #bar < 2 then return nil end
    local target = bar_index(gx)
    local current = target and bar_current(probe)
    if not current then return nil end
    local keys = {}
    if target > current then repeated("right", target - current, keys) else repeated("left", current - target, keys) end
    keys[#keys + 1] = KEY.space
    return keys
end

-- Keys that press the ship command button at (gx, gy); `this` is the highlighted index (THIS-BUTTON).
function M.click_list(gx, gy, this)
    if gx < LIST_X - 3 or gx > 158 then return nil end
    local i = math.floor((LIST_Y0 - gy + 2) / LIST_STEP)
    if i < 0 or not list[i] then return nil end
    local keys = {}
    if i > this then repeated("down", i - this, keys) else repeated("up", this - i, keys) end
    keys[#keys + 1] = KEY.space
    return keys
end

-- Boxed button bars drawn as pictures (the terrain vehicle's MAPS MOVE CARGO...): the buttons are cells between
-- 2-pixel red separators on the bottom rows of the screen, and the highlighted cell has a coloured background.
-- raw(px, py) returns the "r,g,b" of screen pixel (px, py) of the 320x200 picture; `steering` tells that the
-- vehicle is in MOVE mode (the coordinate bar at the top turns green).
local RED = "170,0,0"
function M.click_pixelbar(gx, gy, raw, steering)
    if gy > BAR_TOP + 2 then return nil end
    local row, cells, from = 190, {}, nil
    if raw(2, row) ~= RED or raw(317, row) ~= RED then return nil end        -- the frame of the bar
    local px = 6
    while px < 314 and raw(px, row) == RED do px = px + 1 end                 -- skip the left frame
    from = px
    while px < 314 do
        if raw(px, row) == RED and raw(px + 1, row) == RED then
            if px - from >= 6 then cells[#cells + 1] = {from, px - 1} end
            while px < 314 and raw(px, row) == RED do px = px + 1 end
            from = px
        else
            px = px + 1
        end
    end
    if px - from >= 6 then cells[#cells + 1] = {from, 313} end
    if #cells < 3 then return nil end
    local target, current
    local cx = gx * 2
    for i, c in ipairs(cells) do
        if cx >= c[1] and cx <= c[2] + 2 then target = i end
        if raw(c[1] + 3, row - 1) ~= "0,0,0" and not (current and current < 0) then
            current = current and -1 or i                              -- a second coloured cell: no single highlight
        end
    end
    if not target or not current or current < 0 then return nil end
    local keys = {}
    if steering then                                   -- MOVE is active: arrows drive the vehicle, Return gets back to the bar
        if target == current then return keys end
        keys[1] = KEY.enter
    end
    if target > current then repeated("right", target - current, keys) else repeated("left", current - target, keys) end
    keys[#keys + 1] = KEY.space
    return keys
end

function M.is_save_menu() return save_menu end

-- Keys that choose an option on the Esc menu: 1. SAVE GAME, 2. RESUME GAME, 9. END GAME UNSAVED
function M.click_save_menu(gx, gy)
    if not save_menu then return nil end
    if gx < 15 or gx > 155 then return nil end
    if gy >= 110 and gy <= 130 then
        return {49} -- '1' SAVE GAME
    elseif gy >= 90 and gy <= 110 then
        return {50} -- '2' RESUME GAME
    elseif gy >= 45 and gy <= 65 then
        return {57} -- '9' END GAME UNSAVED
    end
    return nil
end

M.KEY = KEY
return M

-- Boot Starflight 1: load the original files and set up the Forth machine.
local vm = require("vm")
local dos = require("dos")
require("prims")
local hw = require("hw")
local ega = require("ega")
local gfx = require("gfx")
vm.set_video(ega)
for _, port in ipairs{0x3C4, 0x3C5, 0x3CE, 0x3CF, 0x3D4, 0x3D5, 0x3B4, 0x3B5} do
    hw.out_hooks[port] = function(v) ega.out(port, v) end
end
for _, port in ipairs{0x3DA, 0x3BA, 0x3CF} do
    hw.in_hooks[port] = function() return ega.inp(port) end
end
require("ovcode")
local video = require("video")
dos.video = video
hw.scroll = video.scroll
gfx.onmode = function() end

local G = {}

local function readfile(path)
    local f, err = io.open(path, "rb")
    if not f then error("cannot open " .. path .. ": " .. tostring(err)) end
    local d = f:read("*a")
    f:close()
    return d
end
G.readfile = readfile

-- dir: folder holding STARFLT.COM, STARA.COM, STARB.COM (original game files)
function G.boot(dir, opts)
    opts = opts or {}
    local com = opts.com or readfile(dir .. "/STARFLT.COM")
    local mem, DSB = vm.mem, vm.DSB
    require("ffi").fill(mem, 0x110000, 0)
    require("ffi").copy(mem + DSB + 0x100, com, #com)
    mem[DSB], mem[DSB + 1] = 0xCD, 0x20           -- PSP: INT 20h (program exit)
    dos.addfile("A", opts.stara or readfile(dir .. "/STARA.COM"), 256000)
    dos.addfile("B", opts.starb or readfile(dir .. "/STARB.COM"), 362496)
    -- the 16 bytes of start-up code at 0x100 do exactly this:
    local sp = vm.rd16(0x705) + 0x100
    vm.setsp(sp)
    vm.setbp(sp + 0x80)
    vm.setsi(0x129)
    vm.set_di(vm.rd16(0x12B) + 2)
    if opts.patches then G.patches(opts) end
    video.setmode(3)
end

-- Optional patches used by the LÖVE front end (not by the verification tools):
--  * the display-mode question is skipped (EGA is the only mode implemented); in its place the
--    game's own fonts and border draw a "choose a game slot" menu (G.menu_lines, G.menu_active)
--  * the "security code" copy-protection check at launch is removed
--  * G.on_saved() is called when the game finishes saving (the slot file is then consistent)
local thread = require("thread")
local MENU_CFA = 0x38                       -- scratch cell: code address of the menu primitive

local function cfa(name) return thread.cfa(name) end
local function pos(x, y) vm.wr16(0x586E, x); vm.wr16(0x5863, y) end         -- XBLT / YBLT
local function typeline(text)
    for i = 1, #text do vm.wr8(0x60 + i - 1, text:byte(i)) end
    vm.push(0x60); vm.push(#text)
    vm.call(cfa("TYPE"))
end

local menu_drawn = false
local SELECT_COLOR = tonumber(os.getenv('SF_SELCOL') or '') or 2
local TITLE = "STARFLIGHT"
local function draw_menu()
    for _, w in ipairs{"MOUNTA", "LDFONTS", ">DISPLAY", "DARK", "BORDER", "BEEPOFF", ">3FONT"} do vm.call(cfa(w)) end
    -- STARFLIGHT with a line under it: the line (small font, 4 pixels per letter) is as wide as the title,
    -- so the title's letters are spread to the same width
    local sub = "STARGAZER EDITION"
    local width = 4 * #sub - 1
    local seg, spacing = vm.rd16(0x5298), vm.rd16(0x52D9)
    local adv, natural = {}, -1
    for i = 1, #TITLE do
        adv[i] = vm.lrd8(seg, spacing + TITLE:byte(i) - 0x20) + 1
        natural = natural + adv[i]
    end
    local x, extra = 80 - math.floor(width / 2), width - natural
    local cum, cols = 0, {}
    for i = 1, #TITLE do
        cols[i] = x + math.floor(cum + (i - 1) * extra / (#TITLE - 1) + 0.5)
        cum = cum + adv[i]
    end
    local ink = vm.rd16(0x55F2)                                  -- the colour the game starts with
    local function colour(c) vm.push(c); vm.call(cfa("!COLOR")) end
    local function line(x1, y1, x2, y2) vm.push(x2); vm.push(y2); vm.push(x1); vm.push(y1); vm.call(cfa("LLINE")) end
    -- a star like the one on the Binary Systems screen behind the last T: a dithered halo of dark blue and
    -- blue dots that gets denser and lighter towards the middle, a cross of rays and a white core
    local cx, cy = cols[#TITLE] + 2, 178
    local seed = 7
    local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end
    for dy = -19, 19 do
        for dx = -26, 26 do
            local r = math.sqrt((dx / 26) ^ 2 + (dy / 19) ^ 2)
            if r < 1 then
                local p = (1 - r) ^ 0.8
                local v = rnd()
                local c
                if r < 0.22 and v < p then c = 11
                elseif r < 0.45 and v < p * 0.9 then c = (rnd() < 0.5) and 9 or 11
                elseif v < p * 0.6 then c = (rnd() < 0.35) and 9 or 1
                end
                if c then colour(c); line(cx + dx, cy + dy, cx + dx, cy + dy) end
            end
        end
    end
    colour(9); line(cx - 22, cy, cx + 22, cy); line(cx, cy - 18, cx, cy + 18)
    colour(11); line(cx - 14, cy, cx + 14, cy); line(cx, cy - 12, cx, cy + 12)
    line(cx - 6, cy - 6, cx + 6, cy + 6); line(cx - 6, cy + 6, cx + 6, cy - 6)
    colour(15); line(cx - 4, cy, cx + 4, cy); line(cx, cy - 4, cx, cy + 4)
    line(cx - 1, cy - 1, cx + 1, cy - 1); line(cx - 1, cy + 1, cx + 1, cy + 1)
    colour(7); line(cx - 3, cy - 3, cx - 3, cy - 3); line(cx + 4, cy + 2, cx + 4, cy + 2); line(cx - 2, cy + 5, cx - 2, cy + 5)
    -- the title in front of it, every letter with a black outline
    colour(0)
    for i = 1, #TITLE do
        for dx = -1, 1 do
            for dy = -1, 1 do
                if dx ~= 0 or dy ~= 0 then pos(cols[i] + dx, 182 + dy); typeline(TITLE:sub(i, i)) end
            end
        end
    end
    vm.wr16(0x55F2, ink)
    for i = 1, #TITLE do pos(cols[i], 182); typeline(TITLE:sub(i, i)) end
    vm.call(cfa(">1FONT"))
    colour(0)                                                    -- the subtitle: black outline, then cyan
    for dx = -1, 1 do
        for dy = -1, 1 do
            if dx ~= 0 or dy ~= 0 then pos(x + dx, 171 + dy); typeline(sub) end
        end
    end
    colour(11)
    pos(x, 171); typeline(sub)
    vm.wr16(0x55F2, ink)
    vm.call(cfa(">2FONT"))
    local title = G.menu_title or "SELECT A GAME SLOT"
    pos(math.floor(86 - #title * 2.65), 17); typeline(title)            -- centred like the original title
    for n, line in ipairs(G.menu_lines or {}) do
        local y = 142 - (G.menu_step or 12) * (n - 1)
        local sel = n == G.menu_sel
        local old = vm.rd16(0x55F2)
        if sel then vm.push(SELECT_COLOR); vm.call(cfa("!COLOR")) end
        if type(line) == "table" then                     -- {label, value}: the value sits in its own column
            pos(G.menu_x or 34, y); typeline(line[1])
            pos(G.menu_vx or 124, y); typeline(line[2])
        else
            pos(G.menu_x or 34, y); typeline(line)
        end
        vm.wr16(0x55F2, old)
    end
    vm.call(cfa(">0FONT"))
end
-- Draw Stargazer Edition subtitle and star halo onto the Starflight title screen
local function draw_title_stargazer()
    local ega = require("ega")
    local bit = require("bit")
    local function set_pixel(x, y, c)
        if x < 0 or x >= 320 or y < 0 or y >= 200 then return end
        local o = y * 40 + math.floor(x / 8)
        local bitn = 7 - (x % 8)
        local mask = bit.lshift(1, bitn)
        local not_mask = bit.bnot(mask)
        for p = 0, 3 do
            local bit_val = bit.band(bit.rshift(c, p), 1)
            local po = p * 0x10000 + o
            if bit_val == 1 then
                ega.mem[po] = bit.bor(ega.mem[po], mask)
            else
                ega.mem[po] = bit.band(ega.mem[po], not_mask)
            end
        end
    end

    local function get_pixel(x, y)
        if x < 0 or x >= 320 or y < 0 or y >= 200 then return 0 end
        local o = y * 40 + math.floor(x / 8)
        local bitn = 7 - (x % 8)
        local b0 = bit.band(bit.rshift(ega.mem[o], bitn), 1)
        local b1 = bit.band(bit.rshift(ega.mem[0x10000 + o], bitn), 1)
        local b2 = bit.band(bit.rshift(ega.mem[0x20000 + o], bitn), 1)
        local b3 = bit.band(bit.rshift(ega.mem[0x30000 + o], bitn), 1)
        return b0 + 2 * b1 + 4 * b2 + 8 * b3
    end

    local function line(x1, y1, x2, y2, c)
        local dx = math.abs(x2 - x1)
        local dy = math.abs(y2 - y1)
        local sx = x1 < x2 and 1 or -1
        local sy = y1 < y2 and 1 or -1
        local err = dx - dy
        local cx, cy = x1, y1
        while true do
            set_pixel(cx, cy, c)
            if cx == x2 and cy == y2 then break end
            local e2 = 2 * err
            if e2 > -dy then err = err - dy; cx = cx + sx end
            if e2 < dx then err = err + dx; cy = cy + sy end
        end
    end

    -- Star halo centered at the last T of STARFLIGHT (x=258, y=20)
    local cx, cy = 258, 20
    local seed = 7
    local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end

    local is_letter = {}
    for dy = -25, 25 do
        for dx = -30, 30 do
            local px, py = cx + dx, cy + dy
            if get_pixel(px, py) == 15 then
                is_letter[dy * 1000 + dx] = true
            end
        end
    end

    for dy = -19, 19 do
        for dx = -26, 26 do
            if not is_letter[dy * 1000 + dx] then
                local r = math.sqrt((dx / 26) ^ 2 + (dy / 19) ^ 2)
                if r < 1 then
                    local p = (1 - r) ^ 0.8
                    local v = rnd()
                    local c
                    if r < 0.22 and v < p then c = 11
                    elseif r < 0.45 and v < p * 0.9 then c = (rnd() < 0.5) and 9 or 11
                    elseif v < p * 0.6 then c = (rnd() < 0.35) and 9 or 1
                    end
                    if c then set_pixel(cx + dx, cy + dy, c) end
                end
            end
        end
    end

    line(cx - 22, cy, cx + 22, cy, 9); line(cx, cy - 18, cx, cy + 18, 9)
    line(cx - 14, cy, cx + 14, cy, 11); line(cx, cy - 12, cx, cy + 12, 11)
    line(cx - 6, cy - 6, cx + 6, cy + 6, 11); line(cx - 6, cy + 6, cx + 6, cy - 6, 11)
    line(cx - 4, cy, cx + 4, cy, 15); line(cx, cy - 4, cx, cy + 4, 15)
    line(cx - 1, cy - 1, cx + 1, cy - 1, 15); line(cx - 1, cy + 1, cx + 1, cy + 1, 15)
    set_pixel(cx - 3, cy - 3, 7); set_pixel(cx + 4, cy + 2, 7); set_pixel(cx - 2, cy + 5, 7)

    -- Keep white title letters crisp in front
    for k in pairs(is_letter) do
        local dy = math.floor(k / 1000)
        local dx = k - dy * 1000
        set_pixel(cx + dx, cy + dy, 15)
    end

    -- Draw "STARGAZER EDITION" in authentic EGA bitmap font
    local seg = vm.rd16(0x5298)
    local C7, SP7 = vm.rd16(0x52D5), vm.rd16(0x52D9)
    local text = "STARGAZER EDITION"

    local function draw_char(ch, px, py, fg)
        local c = ch:byte()
        local w = vm.lrd8(seg, SP7 + (c - 0x20))
        if w > 8 then w = 8 end
        local addr = (c - 0x20) * 6 + C7
        local word, bitsleft, wi = 0, 0, 0
        for r = 0, 6 do
            for col = 0, w - 1 do
                if bitsleft == 0 then word = vm.lrd16(seg, addr + wi * 2); wi = wi + 1; bitsleft = 16 end
                bitsleft = bitsleft - 1
                if bit.band(bit.rshift(word, bitsleft), 1) == 1 then
                    set_pixel(px + col, py + r, fg)
                end
            end
        end
        return w + 1
    end

    local total_w = 0
    for i = 1, #text do
        local c = text:byte(i)
        total_w = total_w + vm.lrd8(seg, SP7 + (c - 0x20)) + 1
    end

    local tx = math.floor((320 - total_w) / 2)
    local ty = 31

    -- Drop shadow / outline
    for dy = -1, 1 do
        for dx = -1, 1 do
            if dx ~= 0 or dy ~= 0 then
                local cur_x = tx + dx
                for i = 1, #text do
                    cur_x = cur_x + draw_char(text:sub(i, i), cur_x, ty + dy, 0)
                end
            end
        end
    end

    -- Cyan foreground
    local cur_x = tx
    for i = 1, #text do
        cur_x = cur_x + draw_char(text:sub(i, i), cur_x, ty, 11)
    end
end

-- Redraw the menu in place (new selection or page); only valid while the menu is showing.
function G.redraw_menu() draw_menu() end

vm.def(0x7F20, function()
    if not menu_drawn then
        menu_drawn = true
        draw_menu()
    end
    G.menu_active = true
    vm.setsi(vm.getsi() - 2)                -- stay here until the front end restarts the game
    vm.yield = true
end)

function G.patches(opts)
    local hooks = vm.hooks
    for k in pairs(hooks) do hooks[k] = nil end                   -- nothing from an earlier boot (the intro hook!) may linger
    menu_drawn, G.menu_active = false, false
    local function skip() return true end
    G.intro_done = false
    local calls = 0
    hooks[0xB4AF] = function()                                    -- CFIGARRAYS: its second run follows the title screen
        calls = calls + 1
        if calls == 2 then
            G.intro_done = true
            require("music").stop()                               -- the intro song ends with the intro
        end
        return false
    end
    local title_adorned = false
    hooks[0x8BCF] = function()                                    -- >DISPLAY
        if not title_adorned then
            local ega = require("ega")
            if ega.active and ega.mem then
                local bit = require("bit")
                local function px(x, y)
                    local o = y * 40 + math.floor(x / 8)
                    local bitn = 7 - (x % 8)
                    local b0 = bit.band(bit.rshift(ega.mem[o], bitn), 1)
                    local b1 = bit.band(bit.rshift(ega.mem[0x10000 + o], bitn), 1)
                    local b2 = bit.band(bit.rshift(ega.mem[0x20000 + o], bitn), 1)
                    local b3 = bit.band(bit.rshift(ega.mem[0x30000 + o], bitn), 1)
                    return b0 + 2 * b1 + 4 * b2 + 8 * b3
                end
                if px(267, 14) == 15 and px(250, 20) == 15 and px(14, 28) == 15 then
                    title_adorned = true
                    draw_title_stargazer()
                end
            end
        end
        return false
    end
    hooks[0xF456] = function()                                    -- INIT-HYPER-STARS@36
        pcall(function() require("ingamemusic").set_hyperspace(true) end)
        return false
    end
    hooks[0xF4D0] = function()                                    -- HYPER-FRAME@36
        pcall(function() require("ingamemusic").set_hyperspace(true) end)
        return false
    end
    hooks[0xE107] = function()                                    -- SYSSETUP@33
        pcall(function() require("ingamemusic").set_hyperspace(false) end)
        return false
    end
    hooks[0xE12B] = function()                                    -- SYSCLEANUP@33
        pcall(function() require("ingamemusic").set_hyperspace(true) end)
        return false
    end
    -- every string the game draws in graphics mode ({GTYPE}) is reported to G.on_text(string, overlay, x, y)
    hooks[0x945E] = function()
        if G.on_text then
            local sp = vm.getsp()
            local len, addr = vm.rd16(sp), vm.rd16(sp + 2)
            if len > 0 and len < 200 then
                local t = {}
                for i = 0, len - 1 do t[#t + 1] = string.char(vm.rd8(addr + i)) end
                G.on_text(table.concat(t), vm.rd16(0x55A5), vm.rd16(0x586E), vm.rd16(0x5863))
            end
        end
        return false
    end
    -- MS: the game pauses for 5 seconds on arrival ("hull integrity check"); shorten waits over a second
    G.short_delays = true
    hooks[0x2AEF] = function()
        local sp = vm.getsp()
        if G.short_delays and vm.rd16(sp) > 1000 then vm.wr16(sp, 300) end
        return false
    end
    hooks[0xD123] = skip; hooks[0xD134] = skip; hooks[0xD143] = skip        -- SECURE, SIC'EM, 2NDS
    -- SET.DISPLAY.MODE minus the menu: MONITOR=3 (EGA), ?TANDRG off, ?EGA on, then the set-up words
    local cells = {0x175D, 3, 0x84EA, 0x4884, 0x5DA1, 0x4871,          -- LIT 3  ?TANDRG OFF  ?EGA ON
        0x5848, 0x0BDF,                                                -- MONITOR !
        0xE05A, 0x929F, 0xB1BA, 0x8BCF, 0x8EE5, 0x8FBF}                -- SET.COLORS LOAD-CO SETDBUF >DISPLAY >LORES_2 DARK
    if opts.menu then cells[#cells + 1] = MENU_CFA; vm.wr16(MENU_CFA, 0x7F20) end
    cells[#cells + 1] = 0x1690                                         -- EXIT
    for i, c in ipairs(cells) do vm.wr16(0xB0 + (i - 1) * 2, c) end
    -- Esc menu: blank the "3. CHANGE DISPLAY MODE" line just before .GAMEOPS prints it
    local line = "3. CHANGE DISPLAY MODE"
    hooks[0xE4CE] = function()
        for a = 0xE000, 0xF500 do
            local ok = true
            for i = 1, #line do
                if vm.rd8(a + i - 1) ~= line:byte(i) then ok = false; break end
            end
            if ok then for i = 0, #line - 1 do vm.wr8(a + i, 32) end; break end
        end
        return false
    end
    hooks[0xEF58] = function()
        vm.rpush(vm.getsi()); vm.setsi(0xB0)
        return true
    end
    -- WEB21 prints "GAME SAVE COMPLETE": the files hold a finished save at this point
    hooks[0xEB1F] = function()
        if G.on_saved then G.on_saved() end
        return false
    end
end

-- ---------------------------------------------------------------------------
-- Cheat: a full crew of six with every skill at 100, all assigned to their posts, and
-- every ship part at class 5.  Works through the game's own instance routines, so it is
-- applied to the live game and saved by the game's normal Save Game.
-- Instance field offsets (see the disassembly of PERSONNEL-OV, ASSCREW-OV, CONFIG-OV):
--   CREWMEMBER: 0x0A species, 0x0B name[15], 0x1A..0x1E skills, 0x1F vitality, 0x20 status word
--   ASSIGN-CREW: 0x11 six 3-byte crew ids   SHIP: name 0x34 (counted), parts at 0x11/0x13/0x19/0x1B/0x1D (hp, class)
-- ---------------------------------------------------------------------------
local IB = 0x63EF                                -- opened instance buffer
local function cstore(addr, v) vm.push(v); vm.push(addr); vm.call(cfa("C!")) end
local function open(name) vm.call(cfa(name)); vm.call(cfa(">C+S")) end

function G.cheat()
    local names = {"CAPTAIN", "SCIENCE", "NAVIGATOR", "ENGINEER", "COMMS", "DOCTOR"}
    local ids = {}
    open("*PERSON"); vm.call(cfa("IOPEN"))
    for i = 1, 6 do
        cstore(IB + 0x0A, 0)                                    -- Human
        cstore(IB + 0x0B, #names[i])                            -- counted string, 14 chars max
        for k = 1, 14 do cstore(IB + 0x0B + k, (names[i]:byte(k)) or 32) end
        for k = 0x1A, 0x1E do cstore(IB + k, 99) end
        cstore(IB + 0x1F, 99)
        cstore(IB + 0x20, 9); cstore(IB + 0x21, 0)              -- exists + assigned
        vm.call(cfa("CI"))                                      -- ( id.lo id.hi )
        local hi, lo = vm.pop(), vm.pop()
        ids[i] = {lo % 256, math.floor(lo / 256), hi}
        vm.call(cfa("INEXT"))
    end
    vm.call(cfa("ICLOSE"))
    open("*ASSIGN-CREW")
    for i = 1, 6 do for k = 1, 3 do cstore(IB + 0x11 + (i - 1) * 3 + k - 1, ids[i][k]) end end
    vm.call(cfa("ICLOSE"))
    open("*SHIP")
    for _, off in ipairs{0x11, 0x13, 0x19, 0x1B, 0x1D} do cstore(IB + off, 100); cstore(IB + off + 1, 5) end
    local sname = "ARGO"                                              -- %NAME: counted string, 14 chars max
    cstore(IB + 0x34, #sname)
    for k = 1, 14 do cstore(IB + 0x34 + k, sname:byte(k) or 32) end
    for _, off in ipairs{0x30, 0x32} do cstore(IB + off, 0xC4); cstore(IB + off + 1, 0x09) end   -- 2500 points
    vm.call(cfa("ICLOSE"))
end

-- called once per frame: keep the launch "security" state satisfied
function G.tick()
    if vm.rd16(0x5FD1) == 0 then vm.wr16(0x5FD1, 0x7FFF) end
end

return G

-- Starflight 1 for LÖVE: runs the original game data through a Lua port of
-- the game's Forth virtual machine.
--
--   love starflight-lua [path-to-game-files]
--
-- The game files (STARFLT.COM, STARA.COM, STARB.COM) are read from the given
-- folder, from ./games/sf1, or from the LÖVE save directory.  Saved games are
-- written into the save directory; the originals are never modified.

love.filesystem.setRequirePath("src/?.lua;" .. love.filesystem.getRequirePath())

local vm = require("vm")
local dos = require("dos")
local game = require("game")
local video = require("video")
local ega = require("ega")
local hw = require("hw")
local music = require("music")
local ffi = require("ffi")
local crt = require("crt")
local drawer = require("drawer")

-- Settings (slot menu, S): every enhancement can be switched off.  Kept in settings.txt in the save folder.
-- Debug mode turns on the F-key shortcuts (F4 CRT shader, F5 quest log, F6 interface sounds, F7 short waits,
-- F8 enhanced sound, F9 cheat, F10 slot menu, F11 full screen).
local SETTINGS = {                            -- key, label in the menu, default
    {"enhanced", "ENHANCED SOUND", os.getenv("SF_RAW") == nil},
    {"extras", "UI SOUNDS", true}, {"waits", "SHORT WAITS", true}, {"speedcap", "ORBIT SPEED CAP", true},
    {"questlog", "QUEST LOG", true}, {"gamepad", "GAMEPAD", true}, {"mouse", "MOUSE", true}, {"repeatcap", "KEY REPEAT CAP", true},
    {"skipintro", "SKIP SAVED INTRO", true}, {"crt", "CRT SHADER", false}, {"crtglitch", "CRT GLITCHES", true},
    {"remixmusic", "REMIX INTRO MUSIC", true}, {"ingamemusic", "IN-GAME MUSIC", true}, {"debug", "DEBUG MODE", false},
}
local settings = {}
for _, st in ipairs(SETTINGS) do settings[st[1]] = st[3] end
music.is_remix = function() return settings.remixmusic end
local function settings_save()
    local t = {}
    for _, st in ipairs(SETTINGS) do t[#t + 1] = st[1] .. "=" .. (settings[st[1]] and 1 or 0) end
    love.filesystem.write("settings.txt", table.concat(t, "\n") .. "\n")
    if music.sync_remix then music.sync_remix() end
end
local function settings_load()
    local d = love.filesystem.getInfo("settings.txt") and love.filesystem.read("settings.txt")
    for k, v in (d or ""):gmatch("(%w+)=(%d)") do if settings[k] ~= nil then settings[k] = v == "1" end end
    if os.getenv("SF_DEBUG") then settings.debug = (os.getenv("SF_DEBUG") == "1") end
end

-- The game runs unlimited by default, except where its animation is timed by the speed of the
-- machine: the rotating planet and the landing sequence (overlays ORBIT and LAND) are capped
-- at ORBIT_SPEED words/s.  Ctrl+Left / Ctrl+Right set a global cap of SPEED words/s (halve /
-- double), Ctrl+Down goes back to unlimited.
local SPEED = tonumber(os.getenv("SF_SPEED") or "") or 60000
local UNLIMITED = os.getenv("SF_SPEED") == nil
local ORBIT_SPEED = 240000
local SLOW_OVERLAYS = {[0x8186] = true, [0x965B] = true}   -- ORBIT-OV, LAND-OV (directory start >> 4)
local function cap()
    local c = not UNLIMITED and SPEED or nil
    if settings.speedcap and SLOW_OVERLAYS[vm.rd16(0x55A5)] then c = math.min(c or ORBIT_SPEED, ORBIT_SPEED) end
    return c
end
booting = true            -- no speed cap until the game first waits for input
local debt = 0
local speed_msg, speed_t = nil, 0
local function say(m) speed_msg, speed_t = m, love.timer.getTime() end
local FRAME_BUDGET = 0.012
local STEPS_PER_SLICE = 2000
local imagedata, image
local fatal
local getfile, slot = nil, nil           -- slot == nil: the game's own slot menu is showing
local baseline, confirm, quit_ok = nil, nil, false
local cheat_pending = false
local frames = 0
local idle_frames = 0

local function slotfile(n, letter) return "slot" .. n .. "_STAR" .. letter .. ".COM" end
local function flush_slot()
    if not slot then return end
    dos.flush(function(letter, data) love.filesystem.write(slotfile(slot, letter), data) end)
end
-- A slot only ever holds a state the game itself saved: the original refuses to resume anything else.
local function unsaved() return slot and baseline and dos.writes > baseline end

local skip = nil                           -- clicking through the intro of a saved game: {keys = left, t = end time}
-- The menu is a list of items; the game draws it (src/game.lua).  Pages: slots, settings, delete, confirm.
local boot, logfile                      -- defined below
local menu_sel, menu_page, menu_target = 1, "slots", nil
local LAYOUT = {slots = {34, 9}, settings = {20, 9}, delete = {34, 10}, confirm = {34, 12}}   -- x, line step
local menu_items
local function show_menu(nodraw)          -- set the menu up and redraw it in place when the game is already showing it
    local items, title = menu_items()
    game.menu_lines = {}
    for i, it in ipairs(items) do game.menu_lines[i] = it.value and {it.text, it.value} or it.text end
    game.menu_sel, game.menu_title = menu_sel, title
    game.menu_x, game.menu_step = LAYOUT[menu_page][1], LAYOUT[menu_page][2]
    game.menu_vx = 127
    if game.menu_active and not nodraw then game.redraw_menu() end
end
local function goto_page(page, sel, target)
    menu_page, menu_sel, menu_target = page, sel or 1, target
    show_menu()
end
local function slot_text(n)
    local info = love.filesystem.getInfo(slotfile(n, "A"))
    return n .. ". " .. (info and ("SAVED " .. os.date("%m-%d %H:%M", info.modtime)) or "NEW GAME")
end
function menu_items()                -- items {text, value, keys, run}, the page title and what Esc does
    local items, title, back = {}, nil, nil
    local function add(text, keys, run, value) items[#items + 1] = {text = text, value = value, keys = keys, run = run} end
    if menu_page == "settings" then
        title = "SETTINGS"
        back = function() goto_page("slots", 10) end
        for i, st in ipairs(SETTINGS) do
            local key = i <= 9 and tostring(i) or (st[1] == "debug" and "d" or (st[1] == "remixmusic" and "m" or (st[1] == "ingamemusic" and "i" or (st[1] == "crt" and "c" or (st[1] == "crtglitch" and "g" or "a")))))
            add(key:upper() .. ". " .. st[2], {key:lower(), key:upper()}, function()
                settings[st[1]] = not settings[st[1]]; settings_save(); goto_page("settings", i)
            end, settings[st[1]] and "ON" or "OFF")
        end
        add("0. BACK", {"0"}, back)
    elseif menu_page == "delete" then
        title = "DELETE WHICH SAVE?"
        back = function() goto_page("slots", 11) end
        for n = 1, 9 do
            add(slot_text(n), {tostring(n)}, function()
                if love.filesystem.getInfo(slotfile(n, "A")) then goto_page("confirm", 2, n) end
            end)
        end
        add("0. BACK", {"0"}, back)
    elseif menu_page == "confirm" then
        title = "DELETE SLOT " .. menu_target .. "?"
        back = function() goto_page("delete", menu_target) end
        add("Y. YES, DELETE IT", {"y"}, function()
            for _, f in ipairs{slotfile(menu_target, "A"), slotfile(menu_target, "B"), logfile(menu_target)} do
                love.filesystem.remove(f)
            end
            goto_page("delete", menu_target)
        end)
        add("N. NO, KEEP IT", {"n"}, back)
    else
        for n = 1, 9 do add(slot_text(n), {tostring(n)}, function() boot(n) end) end
        add("S. SETTINGS", {"s"}, function() goto_page("settings", 1) end)
        add("D. DELETE A SAVE", {"d"}, function() goto_page("delete", 1) end)
        add("0. QUIT", {"0", "q"}, function() quit_ok = true; love.event.quit() end)
    end
    return items, title, back
end

-- Quest log: what the game tells the player, kept per slot (src/questlog.lua) and shown with F5.
local ql = require("questlog")
local mouse = require("mouse")
local plazawalk = require("plazawalk")
local logslot, logview, loglines = nil, nil, nil
local toggle_log
local function is_in_game()
    return slot ~= nil and not game.menu_active and (game.intro_done == true) and not skip and not fatal and not confirm
end
local demo_t, press_t, presses
function logfile(n) return "slot" .. n .. "_LOG.txt" end
local function log_flush()
    if logslot and ql.dirty then love.filesystem.write(logfile(logslot), ql.serialize()); ql.dirty = false end
end
local function log_select(n)                  -- n = slot, or nil when no game is running
    log_flush()
    logslot, logview, loglines = n, nil, nil
    ql.load(n and love.filesystem.getInfo(logfile(n)) and love.filesystem.read(logfile(n)) or "")
end
game.on_text = function(str, ov, x, y)
    mouse.note(str, x, y, ov)
    if logslot and settings.questlog then ql.add(str, ov, love.timer.getTime(), x, y); loglines = nil end
end

local function slotdata(n, letter)            -- the saved file of slot n, or the original game file
    local p = n and slotfile(n, letter)
    if p and love.filesystem.getInfo(p) then return love.filesystem.read(p) end
    return getfile("STAR" .. letter .. ".COM")
end
-- (re)start the game.  n = slot to play, or nil for the slot menu.  A new game plays the game's intro;
-- a saved one gets it clicked through behind a black screen.
function boot(n)
    hw.keys = {}
    hw.sound.on, hw.music.on, hw.fx.on = false, false, false
    pcall(function() require("remixmusic").stop() end)
    pcall(function() require("ingamemusic").stop_all() end)
    show_menu(true)
    local saved = n and love.filesystem.getInfo(slotfile(n, "A"))
    local ok, err = pcall(game.boot, nil, {patches = true, menu = (n == nil), fastintro = saved and settings.skipintro,
        com = getfile("STARFLT.COM"), stara = slotdata(n, "A"), starb = slotdata(n, "B")})
    if not ok then fatal = tostring(err); return end
    vm.halted, vm.yield = false, false
    slot, baseline, confirm = n, nil, nil
    log_select(n)
    booting = true
    skip = saved and settings.skipintro and {keys = 3} or nil
    game.short_delays = settings.waits
    if os.getenv("SF_RING") then              -- development aid: remember the last Forth words for a crash report
        local names, ovn = vm.names, require("names1ov")
        local ring, cnt = {}, 0
        vm.set_trace(function(w)
            cnt = cnt + 1
            ring[cnt % 60] = string.format("%04X %s sp=%04X OV=%04X", w + 2, names[w + 2] or ovn[w + 2] or "?", vm.getsp(), vm.rd16(0x55A5))
        end)
        vm.dump_ring = function() for i = cnt - 59, cnt do io.stderr:write(tostring(ring[i % 60]), "\n") end end
    end
    game.on_saved = function() flush_slot(); baseline = dos.writes end
end
local tickacc = 0

-- Sound.  Enhanced (default, F8 toggles): src/synth.lua turns the music voice and the TONE/BEEP effects
-- into FM instruments with a reverb; F6 toggles the extras (interface blips, ambience per screen).
-- "PC speaker" (F8) is the raw square wave, band-limited so it does not alias, as the game programs it.
local RATE, CHUNK = 44100, 735
local speaker
local soundchunk
local music = require("music")
local synth = require("synth")
local ph1, gain, lp = 0, 0, 0
local function blep(t, dt)
    if t < dt then t = t / dt; return t + t - t * t - 1
    elseif t > 1 - dt then t = (t - 1) / dt; return t * t + t + t + 1 end
    return 0
end
local sstate = {music = hw.music, fx = hw.fx}
local function setsample(i, v) soundchunk:setSample(i, v) end
local function pump_sound()
    if not speaker then return end
    local sd = hw.sound
    while speaker:getFreeBufferCount() > 0 do
        if skip then
            for i = 0, CHUNK - 1 do soundchunk:setSample(i, 0) end
        elseif settings.enhanced then
            sstate.extras = settings.extras
            sstate.amb = synth.ambience_for(vm.rd16(0x55A5))
            synth.render(CHUNK, setsample, sstate)
        else
            local on = sd.on and sd.freq > 20 and sd.freq < 18000
            local f = on and sd.freq or 0
            local step = f / RATE
            for i = 0, CHUNK - 1 do
                gain = gain + ((on and 1 or 0) - gain) * (on and 0.01 or 0.0015)
                local v = 0
                if gain > 0.0005 and f > 0 then
                    ph1 = (ph1 + step) % 1
                    v = (ph1 < 0.5 and 1 or -1) + blep(ph1, step) - blep((ph1 + 0.5) % 1, step)
                end
                lp = lp + (v * gain * 0.18 - lp) * 0.5
                soundchunk:setSample(i, lp)
            end
        end
        speaker:queue(soundchunk)
        speaker:play()
    end
end

-- scancode-ish key translation: ascii for printable keys, flagged scan codes for others
local SCAN = {
    up = 0x48, down = 0x50, left = 0x4B, right = 0x4D, home = 0x47, ["end"] = 0x4F,
    pageup = 0x49, pagedown = 0x51, insert = 0x52, delete = 0x53,
    f1 = 0x3B, f2 = 0x3C, f3 = 0x3D, f4 = 0x3E, f5 = 0x3F, f6 = 0x40, f7 = 0x41, f8 = 0x42,
    f9 = 0x43, f10 = 0x44,
}
local ASCII = {["return"] = 13, kpenter = 13, escape = 27, backspace = 8, tab = 9}

-- Where the original files come from: a folder, or a zip (mounted through LÖVE's
-- virtual filesystem; the zip is first copied into the save directory).
local function readfile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

local function lower(s) return s:lower() end

local function find_in_vfs(root, name)
    local want = lower(name)
    local function walk(dir, depth)
        for _, item in ipairs(love.filesystem.getDirectoryItems(dir)) do
            local p = dir .. "/" .. item
            local info = love.filesystem.getInfo(p)
            if info and info.type == "file" and lower(item) == want then return p end
            if info and info.type == "directory" and depth < 3 then
                local r = walk(p, depth + 1)
                if r then return r end
            end
        end
    end
    return walk(root, 0)
end

local function zip_source(path)
    local data = readfile(path)
    if not data then return nil end
    love.filesystem.createDirectory("sources")
    local name = "sources/game_" .. (path:match("([^/\\]+)$") or "x.zip")
    love.filesystem.write(name, data)
    local mount = "zip_" .. tostring(#data)
    if not love.filesystem.mount(name, mount) then return nil end
    return function(file)
        local p = find_in_vfs(mount, file)
        return p and love.filesystem.read(p) or nil
    end
end

local function dir_source(dir)
    return function(file)
        local d = readfile(dir .. "/" .. file)
        if d then return d end
        -- case-insensitive fallback on case-sensitive filesystems
        for _, cand in ipairs{file:upper(), file:lower()} do
            d = readfile(dir .. "/" .. cand)
            if d then return d end
        end
        return nil
    end
end

-- returns a function name -> contents, and a description
local function findsource()
    local cands = {}
    local arg1 = arg and arg[2]
    if arg1 and arg1 ~= "" then cands[#cands + 1] = arg1 end
    local base = love.filesystem.getSourceBaseDirectory()
    local src = love.filesystem.getSource()
    for _, d in ipairs{src .. "/games/sf1", base .. "/games/sf1", love.filesystem.getSaveDirectory()} do
        cands[#cands + 1] = d
    end
    cands[#cands + 1] = base .. "/starflight.zip"
    cands[#cands + 1] = src .. "/../starflight.zip"
    for _, c in ipairs(cands) do
        local get
        if c:lower():match("%.zip$") then get = zip_source(c) else get = dir_source(c) end
        if get and get("STARFLT.COM") and get("STARA.COM") and get("STARB.COM") then return get, c end
    end
    return nil, cands
end

function love.load()
    love.graphics.setDefaultFilter("nearest", "nearest")
    imagedata = love.image.newImageData(640, 400)
    image = love.graphics.newImage(imagedata)
    local get, where = findsource()
    if not get then
        fatal = "Cannot find the Starflight files (STARFLT.COM, STARA.COM, STARB.COM).\n\nTried:\n  " ..
            table.concat(where, "\n  ") .. "\n\nCopy them into  games/sf1  or pass a folder or starflight.zip on the command line."
        return
    end
    getfile = get
    -- the old single save becomes slot 1
    for _, l in ipairs{"A", "B"} do
        local old = "save_STAR" .. l .. ".COM"
        if love.filesystem.getInfo(old) and not love.filesystem.getInfo(slotfile(1, l)) then
            love.filesystem.write(slotfile(1, l), love.filesystem.read(old))
            love.filesystem.remove(old)
        end
    end
    settings_load()
    if os.getenv("SF_PRESS") then press_t = love.timer.getTime() + 3 end
    local devslot = tonumber(os.getenv("SF_SLOT") or "")
    if os.getenv("SF_LOGDEMO") then           -- development aid: open the quest log with sample entries
        boot(nil)
        logslot = 99
        local demo_file = os.getenv("SF_LOGFILE") or "slot1_LOG.txt"
        if love.filesystem.getInfo(demo_file) then
            ql.load(love.filesystem.read(demo_file))
        else
            ql.add("01-03-4620", 0, 0)
            local function row(text, x, y, ov, now) for w in text:gmatch("%S+") do ql.add(w, ov, now, x, y); x = x + #w * 3 + 3 end end
            row("1. SEEK OUT AND EXPLORE STRANGE", 50, 100, 0x8A19, 1)
            row("NEW WORLDS", 63, 91, 0x8A19, 1)
            row("WE HAVE LITTLE INFORMATION TO OFFER CONCERNING WHAT YOU MIGHT FIND.", 12, 80, 0x8A19, 1)
            row("WE SUGGEST THAT YOU AVOID THE COORDINATES 135,84 SINCE ALIENS AND ARTIFACTS ARE REPORTED.", 2, 71, 0x8A19, 1)
            row("THE SPEMIN SPEAK OF A WORMHOLE", 4, 100, 0x7C7D, 20)
        end
        demo_t = 2                             -- open once the game has loaded its fonts
        return
    end
    boot(devslot)
    love.keyboard.setKeyRepeat(true)
    love.keyboard.setTextInput(true)
    local ok2, src = pcall(love.audio.newQueueableSource, RATE, 16, 1, 6)
    if ok2 then
        speaker = src
        soundchunk = love.sound.newSoundData(CHUNK, RATE, 16, 1)
    end
    pcall(function() require("remixmusic").init() end)
    pcall(function() require("ingamemusic").init() end)
    drawer.init({
        settings = settings,
        SETTINGS = SETTINGS,
        settings_save = settings_save,
        toggle_log = function(...) return toggle_log(...) end,
        go_menu = function(...) return go_menu(...) end,
        synth = synth,
        is_in_game = is_in_game,
    })
end

function love.quit()
    if os.getenv("SF_DEBUGQUIT") then io.stderr:write("quit called\n", debug.traceback(), "\n") end
    log_flush()
    if not quit_ok and unsaved() then confirm = "quit"; return true end    -- ask first
    return false
end

local paused = false
function love.focus(f) paused = not f end

-- ---------------------------------------------------------------------------
-- quest log viewer
-- ---------------------------------------------------------------------------
local gamefont = require("gamefont")
local KEYS = {"WORMHOLE", "ALIEN", "ACTIVITY", "COORDINATE", "DISTRESS", "SIGNAL", "DERELICT", "ARTIFACT", "TREASURE",
    "STARBASE", "LOCATION", "SECTOR", "BEACON"}
-- EGA colours the game uses
local CYAN, WHITE, YELLOW, LRED, LBLUE = {0.33, 1, 1}, {1, 1, 1}, {0.33, 1, 0.33}, {1, 0.33, 0.33}, {0.33, 0.33, 1}   -- YELLOW is now light green: coordinates
local function spans(line)                    -- split a line into {text, colour} runs: coordinates light green, subjects light red
    local marks = {}
    for a, b in line:gmatch("()%(?%d+%s*[,/]%s*%d+%)?()") do marks[#marks + 1] = {a, b - 1, YELLOW} end
    local u = line:upper()
    for _, k in ipairs(KEYS) do
        local from = 1
        while true do
            local a, b = u:find(k, from, true)
            if not a then break end
            while a > 1 and line:sub(a - 1, a - 1):match("%a") do a = a - 1 end        -- the whole word: ALIENS, ARTIFACTS...
            while line:sub(b + 1, b + 1):match("%a") do b = b + 1 end
            marks[#marks + 1] = {a, b, LRED}
            from = b + 1
        end
    end
    table.sort(marks, function(x, y) return x[1] < y[1] end)
    local out, pos = {}, 1
    for _, m in ipairs(marks) do
        if m[1] >= pos then
            if m[1] > pos then out[#out + 1] = {line:sub(pos, m[1] - 1), WHITE} end
            out[#out + 1] = {line:sub(m[1], m[2]), m[3]}
            pos = m[2] + 1
        end
    end
    if pos <= #line then out[#out + 1] = {line:sub(pos), WHITE} end
    return out
end
local LOGX, LOGW, LOGROW = 14, 296, 9         -- text column, width and row height in screen pixels (320x200)

local function wrap_indent(f, text, first_w, cont_w)
    local lines, line, lw = {}, "", 0
    local cur_w = first_w
    for word in text:gmatch("%S+") do
        local ww = gamefont.width(f, word)
        local sp = gamefont.width(f, " ")
        if line ~= "" and lw + sp + ww > cur_w then
            lines[#lines + 1] = line
            line, lw = word, ww
            cur_w = cont_w
        else
            if line == "" then line, lw = word, ww else line = line .. " " .. word; lw = lw + sp + ww end
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    if #lines == 0 then lines[1] = "" end
    return lines
end

local function build_loglines()
    ql.dedup()
    local f = gamefont.small
    local lines = {}
    for i = #ql.entries, 1, -1 do                        -- newest first
        local e = ql.entries[i]
        lines[#lines + 1] = {head = (e.date ~= "" and e.date .. "   " or "") .. e.src}
        local minx = math.huge
        for _, l in ipairs(e.lines) do
            if l.x then minx = math.min(minx, l.x) end
        end
        if minx == math.huge then minx = 0 end

        -- Group lines into coherent blocks (list items or paragraphs):
        local blocks = {}
        local cur = nil

        -- Pre-process lines to separate any glued list items (e.g. from older single-string logs)
        local raw_lines = {}
        for _, l in ipairs(e.lines) do
            local clean_txt = (l.text or ""):gsub("&+", " "):gsub("%s%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
            if clean_txt ~= "" then
                -- Split on embedded numbered items like " 1. ", " 2. "
                local expanded = clean_txt:gsub("(%s+)(%d+[%.:%)]%s+)", "\n%2")
                for sub in (expanded .. "\n"):gmatch("(.-)\n") do
                    sub = sub:gsub("^%s+", ""):gsub("%s+$", "")
                    if sub ~= "" then
                        raw_lines[#raw_lines + 1] = {x = l.x, text = sub}
                    end
                end
            end
        end

        for _, l in ipairs(raw_lines) do
            local txt = l.text
            local dx = (l.x or 0) - minx
            local is_list_item = txt:match("^%d+[%.:%)]%s*") ~= nil or txt:match("^[%*%-•]%s+") ~= nil
            local is_indented = dx > 15

                if not cur then
                    cur = {is_list = is_list_item, indent = (is_list_item or is_indented) and 12 or 0, text = txt}
                elseif is_list_item then
                    blocks[#blocks + 1] = cur
                    cur = {is_list = true, indent = 12, text = txt}
                elseif cur.is_list then
                    if is_indented then
                        cur.text = cur.text .. " " .. txt
                    else
                        blocks[#blocks + 1] = cur
                        cur = {is_list = false, indent = 0, text = txt}
                    end
                else
                    if is_indented then
                        blocks[#blocks + 1] = cur
                        cur = {is_list = false, indent = 12, text = txt}
                    else
                        cur.text = cur.text .. " " .. txt
                    end
                end
            end
        if cur then blocks[#blocks + 1] = cur end

        for _, b in ipairs(blocks) do
            if b.is_list then
                -- For list items: first line has indent 12; wrapped lines have hanging indent 20
                local first_w = LOGW - 12
                local cont_w = LOGW - 20
                local wrapped = wrap_indent(f, b.text, first_w, cont_w)
                for idx, w in ipairs(wrapped) do
                    local ind = (idx == 1) and 12 or 20
                    lines[#lines + 1] = {runs = spans(w), indent = ind}
                end
            elseif b.indent > 0 then
                -- For indented blockquotes: all lines indent by 12
                local w = LOGW - 12
                local wrapped = gamefont.wrap(f, b.text, w)
                for _, ln in ipairs(wrapped) do
                    lines[#lines + 1] = {runs = spans(ln), indent = 12}
                end
            else
                -- Standard body paragraph: all lines flush left (indent 0)
                local wrapped = gamefont.wrap(f, b.text, LOGW)
                for _, ln in ipairs(wrapped) do
                    lines[#lines + 1] = {runs = spans(ln), indent = 0}
                end
            end
        end
        lines[#lines + 1] = {}
    end
    return lines
end
toggle_log = function()
    if confirm then confirm = nil end
    if logview then
        logview = nil
        return
    end
    if not logslot then
        local found = nil
        if menu_sel and love.filesystem.getInfo(logfile(menu_sel)) then
            found = menu_sel
        else
            for s = 1, 9 do
                if love.filesystem.getInfo(logfile(s)) then found = s; break end
            end
        end
        logslot = found or 1
        ql.load(love.filesystem.getInfo(logfile(logslot)) and love.filesystem.read(logfile(logslot)) or "")
    end
    settings.questlog = true
    logview = {scroll = 0}
    loglines = nil
    gamefont.build()
end
local function log_key(key)
    local v = logview
    local page = 12
    if key == "escape" or key == "f5" or key == "q" then logview = nil
    elseif key == "up" then v.scroll = v.scroll - 1
    elseif key == "down" then v.scroll = v.scroll + 1
    elseif key == "pageup" then v.scroll = v.scroll - page
    elseif key == "pagedown" or key == "space" then v.scroll = v.scroll + page
    elseif key == "home" then v.scroll = 0
    elseif key == "end" then v.scroll = 1e9 end
end

local log_canvas = nil

local function draw_log(W, H)
    if not gamefont.small and not gamefont.build() then return end
    if gamefont.seg ~= vm.rd16(0x5298) then gamefont.build() end
    local sm, lg = gamefont.small, gamefont.large

    if not log_canvas then
        log_canvas = love.graphics.newCanvas(320, 200)
        log_canvas:setFilter("linear", "linear")
    end

    local prev_canvas = love.graphics.getCanvas()
    love.graphics.setCanvas(log_canvas)
    love.graphics.clear(0, 0, 0, 1)

    love.graphics.setColor(0, 0, 0)
    love.graphics.rectangle("fill", 0, 0, 320, 200)
    love.graphics.setColor(LBLUE); love.graphics.rectangle("fill", 0, 0, 320, 3); love.graphics.rectangle("fill", 0, 197, 320, 3)
    love.graphics.rectangle("fill", 0, 0, 3, 200); love.graphics.rectangle("fill", 317, 0, 3, 200)
    love.graphics.setColor(CYAN); love.graphics.rectangle("line", 4.5, 4.5, 311, 191)
    love.graphics.setColor(CYAN)
    gamefont.draw(lg, "QUEST LOG", 12, 9)
    love.graphics.setColor(WHITE)
    local info = string.format("SLOT %d   %d ENTRIES", logslot or 0, #ql.entries)
    gamefont.draw(sm, info, 308 - gamefont.width(sm, info), 12)
    love.graphics.setColor(CYAN); love.graphics.rectangle("fill", 8, 25, 304, 1)
    if not loglines or loglines.n ~= #ql.entries then loglines = {lines = build_loglines(), n = #ql.entries} end
    local lines = loglines.lines
    local top, rows = 30, 17
    logview.scroll = math.max(0, math.min(logview.scroll, math.max(0, #lines - rows)))
    if #lines == 0 then
        love.graphics.setColor(WHITE)
        gamefont.draw(sm, "NOTHING YET.", 12, top)
        love.graphics.setColor(LBLUE)
        gamefont.draw(sm, "NOTICES, WHAT ALIENS TELL YOU AND MESSAGES", 12, top + 18)
        gamefont.draw(sm, "WITH COORDINATES ARE COLLECTED HERE.", 12, top + 27)
    end
    for r = 1, rows do
        local l = lines[logview.scroll + r]
        if not l then break end
        local y = top + (r - 1) * LOGROW
        if l.head then
            love.graphics.setColor(CYAN); gamefont.draw(sm, l.head, 12, y)
        elseif l.runs then
            local x = LOGX + 6 + (l.indent or 0)
            for _, run in ipairs(l.runs) do
                love.graphics.setColor(run[2]); x = x + gamefont.draw(sm, run[1], x, y)
            end
        end
    end
    if #lines > rows then
        local th = 154
        love.graphics.setColor(LBLUE)
        love.graphics.rectangle("fill", 312, top + th * logview.scroll / #lines, 2, math.max(4, th * rows / #lines))
    end
    love.graphics.setColor(LBLUE)
    gamefont.draw(sm, "UP/DOWN/PGUP/PGDN SCROLL     ESC CLOSES", 12, 186)
    love.graphics.setCanvas(prev_canvas)

    local s = math.min(W / 4, H / 3)
    local dw, dh = 4 * s, 3 * s
    if settings.crt then
        crt.render(log_canvas, nil, 320, 200, (W - dw) / 2, (H - dh) / 2, dw, dh, love.timer.getTime(), settings.crtglitch)
    else
        love.graphics.setColor(1, 1, 1)
        love.graphics.draw(log_canvas, (W - dw) / 2, (H - dh) / 2, 0, dw / 320, dh / 200)
    end
end

function love.update(dt)
    drawer.update(dt)
    pcall(function() require("ingamemusic").update(dt, vm.rd16(0x55A5), settings.ingamemusic, is_in_game()) end)
    pad_update()
    pump_keyqueue()
    if plazawalk.busy() then
        if vm.rd16(0x55A5) ~= 0x7660 or not settings.mouse then plazawalk.cancel()
        else plazawalk.update(love.timer.getTime(), vm.rd16(0x586E), vm.rd16(0x5863), vm.rd16(0xECED), function(k) hw.pushkey(k) end) end
    end
    if press_t and love.timer.getTime() > press_t then      -- development aid: SF_PRESS="s down" presses LÖVE keys, 0.7 s apart
        presses = presses or {}
        if #presses == 0 and not presses.done then for tok in os.getenv("SF_PRESS"):gmatch("%S+") do presses[#presses + 1] = tok end; presses.done = true end
        local tok = table.remove(presses, 1)
        local cx, cy, cb = (tok or ""):match("^click:(%d+):(%d+):(%d)$")
        if cx then love.mousepressed(tonumber(cx), tonumber(cy), tonumber(cb)); press_t = love.timer.getTime() + 0.7
        elseif tok then love.keypressed(tok, tok, false); press_t = love.timer.getTime() + 0.7 else press_t = nil end
    end
    if demo_t then demo_t = demo_t - dt; if demo_t <= 0 then demo_t = nil; logview = {scroll = tonumber(os.getenv("SF_LOGSCROLL") or "0")}; gamefont.build() end end
    if logview then log_flush(); return end
    if vm.halted then boot(nil); return end                 -- the game ended: back to the slot menu         -- the game ended (END GAME)
    if fatal or paused then return end
    vm.now = love.timer.getTime
    local t0 = love.timer.getTime()
    -- the cheat runs while the game waits for input, where the Forth machine is at a word boundary
    idle_frames = (hw.polls > 0 or vm.yield) and idle_frames + 1 or 0
    if os.getenv("SF_CHEAT") and frames == tonumber(os.getenv("SF_CHEAT")) then cheat_pending = true end
    if cheat_pending and idle_frames > 2 and not game.menu_active then
        cheat_pending = false
        local ok, err = pcall(game.cheat)
        say(ok and "cheat applied: crew and ship maxed" or ("cheat failed: " .. tostring(err)))
        if os.getenv("SF_CHEAT") then print("cheat:", ok, err) end
    end
    hw.polls = 0
    game.tick()
    tickacc = tickacc + math.min(dt, 0.25)
    while tickacc >= 1 / 18.2 do
        tickacc = tickacc - 1 / 18.2
        music.tick()
    end
    local limit = cap()
    local unlimited = not limit
    if limit then debt = math.min(debt + limit * math.min(dt, 0.1), limit * 0.1) else debt = 0 end
    local ok, err = pcall(function()
        repeat
            local n = (unlimited or booting) and STEPS_PER_SLICE or math.min(STEPS_PER_SLICE, math.floor(debt))
            if n <= 0 then break end
            local left = vm.run(n)
            if booting and (vm.yield or hw.polls > 0) then booting = false; debt = 0 end
            if not unlimited and not booting then debt = debt - (n - left) end
        until vm.yield or hw.polls > 3000 or love.timer.getTime() - t0 > FRAME_BUDGET
    end)
    if skip then                              -- click through the intro of a saved game
        if skip.keys > 0 and hw.polls > 200 and #hw.keys == 0 then
            hw.pushkey(32); skip.keys = skip.keys - 1
            if skip.keys == 0 then skip.t = love.timer.getTime() + 1 end
        elseif skip.t and love.timer.getTime() > skip.t then skip = nil end
    end
    if not ok then
        io.stderr:write("FATAL: ", tostring(err), "\n"); if vm.dump_ring then vm.dump_ring() end
        fatal = tostring(err) .. string.format("\n\nsi=%04X sp=%04X bp=%04X", vm.getsi(), vm.getsp(), vm.getbp())
    end
    logtick = (logtick or 0) + dt
    if logtick > 3 then logtick = 0; log_flush() end
    pump_sound()
end

-- Held keys auto-repeat faster than the game consumes them; only one repeat may be pending.
local repeating = false
local function pushkey(code, isrepeat)
    if settings.repeatcap and (isrepeat and #hw.keys > 0 or #hw.keys >= 8) then return end
    hw.pushkey(code)
end
function love.textinput(t)
    if game.menu_active or confirm or logview then return end
    for i = 1, #t do
        local c = t:byte(i)
        if c >= 32 and c < 127 then pushkey(c, repeating) end
    end
end

-- Gamepad: d-pad or left stick = arrow keys (auto-repeating), A = Return, B = Space, X = Space,
-- Start = Esc, Back = slot menu (F10).  In the slot menu A starts the highlighted entry.
-- Joysticks without a gamepad mapping fall back to hat / first two axes / buttons 1-4, 7-8.
local pad_dir, pad_t = nil, 0                 -- direction being held (d-pad or stick) and its next repeat time
local pad_btn = nil                           -- d-pad direction currently pressed, if any
local DIRS = {dpup = "up", dpdown = "down", dpleft = "left", dpright = "right"}
local HATS = {u = "up", d = "down", l = "left", r = "right"}
local function pad_key(k) love.keypressed(k, k, false) end
local function pad_press(b)                    -- b: logical button a/b/x/start/back
    if b == "a" then pad_key(confirm and "y" or "return")
    elseif b == "x" then pad_key("space")
    elseif b == "b" then pad_key(confirm and "n" or (game.menu_active and "escape" or "space"))
    elseif b == "start" then
        if confirm then pad_key("n") elseif not game.menu_active then pad_key("escape") end
    elseif b == "back" then go_menu()
    elseif b == "y" then toggle_log()
    end
end
local function pad_start(dir)
    pad_dir, pad_t = dir, love.timer.getTime() + 0.3
    pad_key(dir)
end
function love.gamepadpressed(joy, b)
    if not settings.gamepad then return end
    if DIRS[b] then pad_btn = DIRS[b]; pad_start(pad_btn) else pad_press(b) end
end
function love.gamepadreleased(joy, b) if DIRS[b] and pad_btn == DIRS[b] then pad_btn = nil end end
-- Keyboards and mice also show up as "joysticks" (media keys, system control); their idle hat or axis would
-- look like a pressed direction.  Only gamepad-mapped devices and real unmapped sticks are used.
local function usable(joy)
    if joy:isGamepad() then return true end
    local name = joy:getName():lower()
    if name:find("keyboard") or name:find("system control") or name:find("mouse") or name:find("consumer")
        or name:find("touchpad") or name:find("dongle") then return false end
    return joy:getAxisCount() >= 2 and joy:getButtonCount() >= 4
end
local RAW = {[1] = "a", [2] = "b", [3] = "x", [4] = "b", [7] = "back", [8] = "start", [9] = "start", [10] = "start"}
function love.joystickpressed(joy, b)
    if not settings.gamepad or joy:isGamepad() or not usable(joy) then return end
    if RAW[b] then pad_press(RAW[b]) end
end
function love.joystickhat(joy, hat, dir)
    if not settings.gamepad or joy:isGamepad() or not usable(joy) then return end
    local d = HATS[dir:sub(1, 1)]
    if d then pad_btn = d; pad_start(d) else pad_btn = nil end
end
local stick = nil
function pad_update()
    if not settings.gamepad then return end
    local x, y
    for _, joy in ipairs(love.joystick.getJoysticks()) do
        if not usable(joy) then
        elseif joy:isGamepad() then x, y = joy:getGamepadAxis("leftx"), joy:getGamepadAxis("lefty")
        else x, y = joy:getAxis(1), joy:getAxis(2) end
        if x and (math.abs(x) > 0.5 or math.abs(y) > 0.5) then break end
    end
    local sd
    if x and (math.abs(x) > 0.5 or math.abs(y) > 0.5) then
        if math.abs(x) > math.abs(y) then sd = x < 0 and "left" or "right" else sd = y < 0 and "up" or "down" end
    end
    if sd ~= stick then
        stick = sd
        if sd then pad_start(sd) end
    end
    local d = pad_btn or stick
    if d and love.timer.getTime() >= pad_t then
        pad_t = love.timer.getTime() + 0.09
        repeating = true; love.keypressed(d, d, true); repeating = false
    end
end

-- ---------------------------------------------------------------------------
-- mouse (src/mouse.lua turns clicks on the game's buttons into the keys that press them)
-- ---------------------------------------------------------------------------
-- Keys made by the mouse are paced like typing: the game ignores keys that follow each other too closely.
local keyqueue = {}
local function queue_keys(keys)
    local t = love.timer.getTime()
    if #keyqueue > 0 then t = math.max(t, keyqueue[#keyqueue].t) end
    for _, k in ipairs(keys) do t = t + 0.12; keyqueue[#keyqueue + 1] = {t = t, key = k} end
end
function pump_keyqueue()
    local now = love.timer.getTime()
    while keyqueue[1] and keyqueue[1].t <= now do hw.pushkey(table.remove(keyqueue, 1).key) end
end

local function to_game(x, y)                  -- window position -> game pixels (x 0..159, y 0 at the bottom), nil outside the picture
    local W, H = love.graphics.getDimensions()
    local sc = math.min(W / 4, H / 3)
    local u = (x - (W - 4 * sc) / 2) / (4 * sc)
    local v = (y - (H - 3 * sc) / 2) / (3 * sc)
    if u < 0 or u > 1 or v < 0 or v > 1 then return nil end
    local vx, vy
    if settings.crt then
        vx, vy = crt.to_game(u, v)
        if not vx then return nil end
    else
        vx, vy = u * 320, v * 200
    end
    return vx / 2, 199 - vy
end
local probebuf = ffi.new("uint8_t[?]", 320 * 200 * 4)
local function raw(px, py)                    -- colour of pixel (px, py) of the 320x200 picture, as "r,g,b"
    local o = (py * 320 + px) * 4
    return probebuf[o] .. "," .. probebuf[o + 1] .. "," .. probebuf[o + 2]
end
local function probe(gx, gy) return raw(math.floor(gx * 2), 199 - gy) end   -- the same for game pixels
local function menu_hit(gx, gy)               -- number of the menu item under the pointer
    local items = menu_items()
    local step = LAYOUT[menu_page][2]
    if gx < 8 or gx > 152 then return nil end
    for n = 1, #items do
        if math.abs(gy - (142 - step * (n - 1) - 3)) <= step / 2 then return n end
    end
end
function love.mousemoved(x, y)
    if not settings.mouse or not game.menu_active or confirm or logview then return end
    local gx, gy = to_game(x, y)
    local n = gx and menu_hit(gx, gy)
    if n and n ~= menu_sel then menu_sel = n; show_menu() end
end
function love.mousepressed(x, y, button)
    if drawer.mousepressed(x, y, button) then return end
    if not settings.mouse or skip then return end
    if logview then if button == 2 then logview = nil end; return end
    if confirm then if button == 2 then confirm = nil end; return end
    local gx, gy = to_game(x, y)
    if not gx then return end
    if game.menu_active then
        if button == 2 then
            local _, _, back = menu_items()
            if back then back() end
        elseif button == 1 then
            local n = menu_hit(gx, gy)
            if n then menu_sel = n; menu_items()[n].run() end
        end
        return
    end
    if baseline == nil and slot then baseline = dos.writes end   -- first input: from here on changes count
    if button == 2 then
        plazawalk.cancel()
        if mouse.is_save_menu and mouse.is_save_menu() then
            queue_keys({50}) -- right click on save menu: resume (option 2)
            return
        end
        queue_keys({27}); return   -- right click: Esc
    end
    if button ~= 1 then return end
    if vm.rd16(0x55A5) == 0x7660 and video.mode == "graphics" then          -- the rotunda: walk there
        ega.render(probebuf)
        plazawalk.click(gx, gy, raw)
        return
    end
    local keys
    if video.mode == "graphics" then
        ega.render(probebuf)
        keys = mouse.click_save_menu(gx, gy) or mouse.click_bar(gx, gy, probe) or mouse.click_pixelbar(gx, gy, raw, raw(30, 4) == "85,255,85")   -- green coordinate bar: MOVE is steering or mouse.click_list(gx, gy, vm.rd16(0x5BA3))
    end
    if os.getenv("SF_DEBUGMOUSE") then io.stderr:write(string.format("click gx=%.1f gy=%.1f keys=%s\n", gx, gy, keys and table.concat(keys, ",") or "none")) end
    queue_keys(keys or {32})                                   -- anywhere else: Space
end
function love.wheelmoved(dx, dy)
    if not settings.mouse or skip or dy == 0 then return end
    local up = dy > 0
    if logview then logview.scroll = logview.scroll + (up and -3 or 3); return end
    if confirm then return end
    if game.menu_active then
        local items = menu_items()
        menu_sel = (menu_sel - 1 + (up and -1 or 1)) % #items + 1
        show_menu()
        return
    end
    queue_keys({up and 0x4800 or 0x5000})
end

function go_menu()                            -- back to the slot menu (asks first when the game is unsaved)
    if game.menu_active or confirm then return end
    if unsaved() then confirm = "menu" else boot(nil) end
end
function love.keypressed(key, scancode, isrepeat)
    if drawer.keypressed(key) then return end
    repeating = isrepeat
    plazawalk.cancel()
    local ctrl, alt = love.keyboard.isDown("lctrl", "rctrl"), love.keyboard.isDown("lalt", "ralt")
    if logview then if not isrepeat or key ~= "f5" then log_key(key) end; return end
    if not isrepeat then                      -- shortcuts that are always on
        if ctrl and key == "l" then toggle_log(); return end
        if ctrl and key == "q" then go_menu(); return end
        if ctrl and (key == "g" or key == "f3") then
            settings.crtglitch = not settings.crtglitch; settings_save()
            say(settings.crtglitch and "CRT glitches: on" or "CRT glitches: off")
            return
        end
        if alt and (key == "return" or key == "kpenter") then love.window.setFullscreen(not love.window.getFullscreen()); return end
    end
    if settings.debug and (key:match("^f%d+$") or key == "g") and not game.menu_active and not confirm then
        if isrepeat then return end
        if key == "f3" or key == "g" then
            settings.crtglitch = not settings.crtglitch; settings_save(); say(settings.crtglitch and "CRT glitches: on" or "CRT glitches: off")
        elseif key == "f4" then settings.crt = not settings.crt; settings_save(); say(settings.crt and "CRT shader: on" or "CRT shader: off")
        elseif key == "f5" then toggle_log()
        elseif key == "f6" then settings.extras = not settings.extras; say(settings.extras and "interface sounds: on" or "interface sounds: off")
        elseif key == "f7" then game.short_delays = not game.short_delays
            say(game.short_delays and "long waits: shortened" or "long waits: original length")
        elseif key == "f8" then settings.enhanced = not settings.enhanced; say(settings.enhanced and "sound: enhanced" or "sound: PC speaker")
        elseif key == "f9" then cheat_pending = true; say("cheat: crew and ship will be set up")
        elseif key == "f10" then go_menu()
        elseif key == "f11" then love.window.setFullscreen(not love.window.getFullscreen())
        else goto forward end
        return
    end
    ::forward::
    if settings.extras and settings.enhanced and not isrepeat then
        if key == "up" or key == "down" or key == "left" or key == "right" then synth.blip("tick")
        elseif key == "return" or key == "kpenter" or key == "space" then synth.blip("ok")
        elseif key == "escape" then synth.blip("back") end
    end
    if confirm then
        if key == "y" then
            if confirm == "quit" then quit_ok = true; love.event.quit() else boot(nil) end
        elseif key == "n" or key == "escape" then confirm = nil end
        return
    end
    if game.menu_active then
        local items, _, back = menu_items()
        local k = key:match("^kp(%d)$") or key
        if k == "escape" or k == "backspace" then
            if back then back() end
        elseif k == "up" or k == "down" then
            menu_sel = (menu_sel - 1 + (k == "up" and -1 or 1)) % #items + 1
            show_menu()
        elseif k == "return" or k == "kpenter" or k == "space" then
            items[menu_sel].run()
        else
            for _, it in ipairs(items) do
                for _, kk in ipairs(it.keys) do
                    if kk:lower() == k:lower() then it.run(); return end
                end
            end
            if k:lower() == "g" then
                settings.crtglitch = not settings.crtglitch
                settings_save()
                say(settings.crtglitch and "CRT glitches: on" or "CRT glitches: off")
                if menu_page == "settings" then show_menu() end
                return
            end
        end
        return
    end
    if baseline == nil and slot then baseline = dos.writes end   -- first key press: from here on changes count
    if ctrl then
        if key == "left" then SPEED = math.max(2000, SPEED / 2); UNLIMITED = false
        elseif key == "right" then SPEED = math.min(4000000, SPEED * 2); UNLIMITED = false
        elseif key == "down" then UNLIMITED = true
        else goto normal end
        say(UNLIMITED and "speed: unlimited" or string.format("speed: %d words/s", SPEED))
        do return end
    end
    ::normal::
    if ASCII[key] then pushkey(ASCII[key], isrepeat)
    elseif SCAN[key] then pushkey(0x100 * SCAN[key], isrepeat)    -- ascii 0, scan code in the high byte
    end
end

-- development aid: SF_SHOT=file.png SF_FRAMES=n SF_KEYS="5 ENTER" saves a screenshot and exits
local shot_path = os.getenv("SF_SHOT")
local shot_frames = tonumber(os.getenv("SF_FRAMES") or "120")
local injected = false
local shot_t0, shot_done
local function dev_hooks()
    if os.getenv("SF_SHOTFILE") then            -- screenshot into the save folder after SF_SHOTAFTER seconds
        local t = love.timer.getTime()
        shot_t0 = shot_t0 or t
        local after = tonumber(os.getenv("SF_SHOTAFTER") or "10")
        if not shot_done and t - shot_t0 > after then shot_done = t; love.graphics.captureScreenshot(os.getenv("SF_SHOTFILE")) end
        if shot_done and t - shot_done > 2 then quit_ok = true; love.event.quit() end
    end
    if not shot_path and not os.getenv("SF_KEYS") then return end
    if not injected then
        injected = true
        for _, k in ipairs(require("keys").parse(os.getenv("SF_KEYS") or "")) do hw.pushkey(k) end
    end
    frames = frames + 1
    if shot_path and frames == shot_frames then
        love.graphics.captureScreenshot(function(img)
            local fd = img:encode("png")
            local f = io.open(shot_path, "wb")
            if f then f:write(fd:getString()); f:close() else love.filesystem.write(shot_path, fd:getString()) end
            quit_ok = true
            love.event.quit()
        end)
    end
end

function love.draw()
    local W, H = love.graphics.getDimensions()
    if fatal then
        love.graphics.setColor(1, 0.4, 0.4)
        love.graphics.printf(fatal, 20, 20, W - 40)
        return
    end
    if logview then
        draw_log(W, H)
        if speed_msg and love.timer.getTime() - speed_t < 2 then
            love.graphics.setColor(1, 1, 0)
            love.graphics.print(speed_msg, 8, 8)
        end
        drawer.draw(W, H)
        dev_hooks()
        return
    end
    if skip then return end                  -- black while the intro of a saved game is clicked through
    local w, h
    local buf = ffi.cast("uint8_t*", imagedata:getFFIPointer())
    if video.mode == "graphics" then
        ega.render(buf, 640)
        w, h = 320, 200
    else
        video.render_text(buf)
        w, h = 640, 400
    end
    image:replacePixels(imagedata)
    local quad = love.graphics.newQuad(0, 0, w, h, 640, 400)
    -- the original monitor showed both modes at 4:3
    local s = math.min(W / 4, H / 3)
    local dw, dh = 4 * s, 3 * s
    if settings.crt then
        crt.render(image, quad, w, h, (W - dw) / 2, (H - dh) / 2, dw, dh, love.timer.getTime(), settings.crtglitch)
    else
        love.graphics.setColor(1, 1, 1)
        love.graphics.draw(image, quad, (W - dw) / 2, (H - dh) / 2, 0, dw / w, dh / h)
    end
    if confirm then
        love.graphics.setColor(0, 0, 0, 0.8); love.graphics.rectangle("fill", 0, H / 2 - 50, W, 100)
        love.graphics.setColor(1, 1, 0)
        love.graphics.printf("This game has not been saved (Esc, then 1, in the game).\nProgress since the last save will be lost.\n\nLeave anyway?   Y = yes   N = no",
            0, H / 2 - 40, W, "center")
    end
    if speed_msg and love.timer.getTime() - speed_t < 2 then
        love.graphics.setColor(1, 1, 0)
        love.graphics.print(speed_msg, 8, 8)
    end
    drawer.draw(W, H)
    dev_hooks()
end

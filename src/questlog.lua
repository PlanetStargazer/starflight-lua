-- Quest log: collects the information the game shows the player (starport notices, what aliens say,
-- coordinates, warnings) so it can be read again at any time.  The front end feeds it every string the
-- game draws ({GTYPE}); this module decides what is worth keeping and groups lines into entries.
local M = {}

M.entries = {}          -- oldest first: {date =, src =, lines = {{x = indent, text = ...}, ...}, text = lines joined}
M.dirty = false
local date = nil
local last_t = -10
local last_src

-- Screens whose text is always kept (value of OV#: directory start >> 4), and a label for each.
local SOURCES = {
    [0x7C7D] = "COMMUNICATIONS", [0x7E41] = "COMMUNICATIONS",
    [0x8A19] = "OPERATIONS",
}
local UI = {NOTICES = true, EVALUATION = true, EXIT = true, INTERSTEL = true, OPERATIONS = true,
    ["ORBITAL DIVISION"] = true, ["REPEAT LAST NOTICE? [N Y]"] = true, ["NO NEW NOTICES"] = true}
-- Anywhere else, text is kept when it carries coordinates or one of these subjects.
local KEYWORDS = {"WORMHOLE", "ALIEN", "ACTIVITY", "COORDINATE", "DISTRESS", "SIGNAL", "DERELICT",
    "ARTIFACT", "TREASURE", "STARBASE", "LOCATED", "LOCATION", "SECTOR", "BEACON", "ENCOUNTER"}

local function interesting(str)
    if #str < 10 then return false end
    if str:find("%d+%s*[,/]%s*%d+") then return true end
    local u = str:upper()
    for _, k in ipairs(KEYWORDS) do if u:find(k, 1, true) then return true end end
    return false
end

-- Labels of the screens' own buttons and prompts: never worth keeping.
local LABELS = {"NEXT MESSAGE", "PREVIOUS MESSAGE", "PRESS SPACEBAR", "ABORT CURRENT", "END NOTICES", "END OF NOTICES",
    "REPEATING LAST", "REPEAT LAST", "[ QUIT ]", "PRESS ANY KEY", "NOTICE ABORTED"}
local function is_label(str)
    local u = str:upper()
    for _, l in ipairs(LABELS) do if u:find(l, 1, true) then return true end end
    return false
end

-- Banners the game prints between ***...*** (end of notices, notice aborted, ...) are not information.
-- Ampersands (&) were used by the original Forth bytecode as space/newline placeholders.
local function clean(text)
    text = text:gsub("%*%*%*[^*]-%*%*%*", ""):gsub("&+", " "):gsub("%s%s+", " ")
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local muted = false          -- true while a notice is being replayed (it is already in the log)
local in_eval = false        -- true while the evaluation screen is active
local last_ov

local function is_eval_text(s)
    if not s then return false end
    local u = s:upper()
    if u:find("YOU HAVE NOT FILED ANY", 1, true) then return true end
    if u:find("COLONY WORLD RECOMMENDATION", 1, true) then return true end
    if u:find("RECOMMENDATION:", 1, true) then return true end
    if u:find("EVALUATION:", 1, true) then return true end
    if u:find("SUPPLEMENTAL EVALUATION", 1, true) then return true end
    if u:find("LOSS OF TERRAIN VEHICLE", 1, true) then return true end
    if u:find("TOWING CHARGES", 1, true) then return true end
    if u:find("COMPLETION OF MISSION", 1, true) then return true end
    if u:find("END OF EVALUATIONS", 1, true) then return true end
    if u:find("FOR NEXT EVALUATION", 1, true) then return true end
    return false
end

local function norm_text(s)
    if not s then return "" end
    s = s:gsub("&+", " ")
    s = s:gsub("[%p%s%c]+", " ")
    return s:upper():gsub("^%s+", ""):gsub("%s+$", "")
end

local function is_duplicate(e1, e2)
    local n1 = norm_text(e1.text)
    local n2 = norm_text(e2.text)
    if n1 == "" or n2 == "" then return false end
    if n1 == n2 then return true end

    local min_len = math.min(#n1, #n2)
    if min_len >= 30 then
        if n1:find(n2, 1, true) or n2:find(n1, 1, true) then
            return true
        end
        if min_len >= 35 and n1:sub(1, 35) == n2:sub(1, 35) then
            return true
        end
    end
    return false
end

local function retext(e)
    local t = {}
    for _, l in ipairs(e.lines or {}) do t[#t + 1] = l.text end
    e.text = table.concat(t, " ")
end

-- Deduplicate entries list: removes duplicates and evaluation text, keeping the most complete entry
function M.dedup()
    local clean_entries = {}
    for _, e in ipairs(M.entries) do
        if not is_eval_text(e.text) and (e.text or "") ~= "" then
            local dup_idx = nil
            for idx, existing in ipairs(clean_entries) do
                if is_duplicate(e, existing) then
                    dup_idx = idx
                    break
                end
            end
            if dup_idx then
                local existing = clean_entries[dup_idx]
                local n_new = #norm_text(e.text)
                local n_old = #norm_text(existing.text)
                if n_new > n_old then
                    if (not e.date or e.date == "") and (existing.date and existing.date ~= "") then
                        e.date = existing.date
                    end
                    clean_entries[dup_idx] = e
                elseif (not existing.date or existing.date == "") and (e.date and e.date ~= "") then
                    existing.date = e.date
                end
            else
                clean_entries[#clean_entries + 1] = e
            end
        end
    end
    M.entries = clean_entries
end

-- called for each string the game draws, at column x of row y (game pixels); now = seconds (any clock).
-- The game types messages word by word: strings typed shortly after each other make one entry, words on
-- the same row make one line, and the column of a line's first word keeps the screen's indentation.
function M.add(str, ov, now, x, y)
    str = str:gsub("%s+$", ""):gsub("^%s+", "")
    if str == "" then return end
    if ov ~= last_ov then muted = false; in_eval = false; last_ov = ov end        -- leaving the screen ends a replay

    -- Evaluation screen tracking: do not log anything from the Evaluation screen
    if ov == 0x8A19 then
        if str == "EVALUATION" and (y and y <= 12) then
            in_eval = true
            return
        elseif str == "NOTICES" or str:match("^%d%d%-%d%d%-%d%d%d%d$") or str:find("NO NEW NOTICES", 1, true) or str:find("REPEAT LAST NOTICE", 1, true) then
            in_eval = false
        elseif is_eval_text(str) then
            in_eval = true
        end
    else
        in_eval = false
    end

    if in_eval or is_eval_text(str) then
        if #M.entries > 0 and is_eval_text(M.entries[#M.entries].text) then
            table.remove(M.entries)
            M.dirty = true
        end
        return
    end

    if str:upper():find("REPEATING", 1, true) then muted = true; return end
    if str:upper():find("REPEAT LAST NOTICE", 1, true) then muted = false; return end
    if muted then return end
    if str:match("^%d%d%-%d%d%-%d%d%d%d$") then date = str; return end
    if is_label(str) then return end
    local src = SOURCES[ov]
    if src then
        if UI[str] then return end
    elseif interesting(str) then
        src = "SHIP"
    else
        return
    end
    local last = M.entries[#M.entries]
    if last and last.src == src and now - last_t < 2.0 then
        local ln = last.lines[#last.lines]
        if ln and y and ln.y == y then                            -- the next word on the same row
            local glue = (str:match("^[,.;:!?)]") or ln.text:match("%($")) and "" or " "
            ln.text = clean(ln.text .. glue .. str)
            if ln.text == "" then last.lines[#last.lines] = nil end
        else
            local t = clean(str)
            if t ~= "" then last.lines[#last.lines + 1] = {x = x or 0, y = y, text = t} end
        end
        if #last.lines == 0 then M.entries[#M.entries] = nil else retext(last) end
    else
        M.dedup()
        local t = clean(str)
        if t == "" then return end
        local e = {date = date or "", src = src, lines = {{x = x or 0, y = y, text = t}}}
        retext(e)
        M.entries[#M.entries + 1] = e
    end
    last_t = now
    M.dirty = true
end

function M.clear() M.entries, M.dirty, date, last_t, in_eval = {}, false, nil, -10, false end

-- text form: one entry per line, fields separated by tabs (date, source, text); the text holds the entry's
-- lines as "indent|words", separated by \n
local function escape(t) return (t:gsub("\\", "\\\\"):gsub("\n", "\\n")) end
function M.serialize()
    M.dedup()
    local out = {}
    for _, e in ipairs(M.entries) do
        local ls = {}
        for _, l in ipairs(e.lines) do ls[#ls + 1] = l.x .. "|" .. l.text end
        out[#out + 1] = e.date .. "\t" .. e.src .. "\t" .. escape(table.concat(ls, "\n"))
    end
    return table.concat(out, "\n") .. "\n"
end
function M.load(data)
    M.clear()
    for line in (data or ""):gmatch("[^\n]+") do
        local d, s, t = line:match("^(.-)\t(.-)\t(.*)$")
        if d then
            local pieces, indented = {}, false
            -- split on the \n escapes (a backslash pair is a literal backslash)
            t = t:gsub("\\\\", "\1"):gsub("\\n", "\2"):gsub("\1", "\\")
            for piece in (t .. "\2"):gmatch("(.-)\2") do
                local x, text = piece:match("^(%d+)|(.*)$")
                if x then indented = true; pieces[#pieces + 1] = {x = tonumber(x), text = text}
                else pieces[#pieces + 1] = {x = 0, text = piece} end
            end
            -- Filter out any evaluation lines from loaded pieces
            local clean_pieces = {}
            for _, pc in ipairs(pieces) do
                if not is_eval_text(pc.text) then
                    clean_pieces[#clean_pieces + 1] = pc
                end
            end
            if #clean_pieces > 0 then
                local e = {date = d, src = s}
                if indented then e.lines = clean_pieces
                else
                    local words = {}
                    for _, pc in ipairs(clean_pieces) do words[#words + 1] = pc.text end
                    e.lines = {{x = 0, text = table.concat(words, " ")}}
                end
                retext(e)
                if not is_eval_text(e.text) then
                    M.entries[#M.entries + 1] = e
                end
            end
        end
    end
    M.dedup()
    M.dirty = false
end

return M

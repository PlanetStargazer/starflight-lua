-- Key scripts for the dev tools: whitespace separated tokens.
--   a single character  -> that ASCII key         SP, ENTER, ESC, BS, TAB
--   UP DOWN LEFT RIGHT HOME END PGUP PGDN INS DEL F1..F10 -> extended keys
--   N*TOKEN             -> TOKEN repeated N times
local K = {}
local named = {SP = 32, ENTER = 13, ESC = 27, BS = 8, TAB = 9,
    UP = 0x4800, DOWN = 0x5000, LEFT = 0x4B00, RIGHT = 0x4D00, HOME = 0x4700, END = 0x4F00,
    PGUP = 0x4900, PGDN = 0x5100, INS = 0x5200, DEL = 0x5300}
for i = 1, 10 do named["F" .. i] = (0x3A + i) * 256 end
function K.parse(s)
    local out = {}
    for tok in s:gmatch("%S+") do
        local n, t = tok:match("^(%d+)%*(.+)$")
        n = tonumber(n) or 1
        t = t or tok
        local code = named[t] or (#t == 1 and t:byte()) or error("bad key token " .. tok)
        for _ = 1, n do out[#out + 1] = code end
    end
    return out
end
return K

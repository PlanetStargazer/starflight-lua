-- The game's own bitmap fonts, read from the font segment the game has loaded (nothing is stored here).
--   small font ({2FONT}): 7 rows, characters 0x20..0x5A, 6 bytes per glyph at 7CHAR
--   large font ({3FONT}): 9 rows, capitals A..Z only, 8 bytes per glyph at 9CHAR
-- Glyph bits run row by row, most significant bit first, 16 bits per little-endian word; the width of
-- each character is a byte at 7SPACING + (char - 0x20).
local vm = require("vm")
local bit = require("bit")
local F = {}

local FONTSEG, C7, SP7, C9 = 0x5298, 0x52D5, 0x52D9, 0x52DD

local function glyph(seg, addr, w, rows)
    local px = {}
    local word, bitsleft, wi = 0, 0, 0
    for r = 0, rows - 1 do
        for c = 0, w - 1 do
            if bitsleft == 0 then word = vm.lrd16(seg, addr + wi * 2); wi = wi + 1; bitsleft = 16 end
            bitsleft = bitsleft - 1
            if bit.band(bit.rshift(word, bitsleft), 1) == 1 then px[#px + 1] = {c, r} end
        end
    end
    return px
end

local function make(seg, rows, first, last, bytes, base, spacing)
    local f = {rows = rows, w = {}, quad = {}, first = first, last = last}
    local n = last - first + 1
    local data = love.image.newImageData(n * 8, rows)
    for ch = first, last do
        local w = vm.lrd8(seg, spacing + (ch - 0x20))
        if w > 8 then w = 8 end
        f.w[ch] = w
        for _, p in ipairs(glyph(seg, (ch - first) * bytes + base, w, rows)) do
            data:setPixel((ch - first) * 8 + p[1], p[2], 1, 1, 1, 1)
        end
    end
    f.image = love.graphics.newImage(data)
    f.image:setFilter("nearest", "nearest")
    for ch = first, last do f.quad[ch] = love.graphics.newQuad((ch - first) * 8, 0, 8, rows, n * 8, rows) end
    return f
end

-- (re)build the glyph atlases; false when the game has not loaded its fonts yet
function F.build()
    local seg = vm.rd16(FONTSEG)
    if seg == 0 then return false end
    local ok, small, large = pcall(function()
        return make(seg, 7, 0x20, 0x5A, 6, vm.rd16(C7), vm.rd16(SP7)), make(seg, 9, 0x41, 0x5A, 8, vm.rd16(C9), vm.rd16(SP7))
    end)
    if not ok or not small or (small.w[65] or 0) == 0 then return false end
    F.small, F.large, F.seg = small, large, seg
    return true
end

local function code(ch, f)
    local c = ch:byte()
    if c >= 97 and c <= 122 then c = c - 32 end            -- the fonts have capitals only
    if c < f.first or c > f.last then return nil end
    return c
end

function F.width(f, text)
    local w = 0
    for i = 1, #text do
        local c = code(text:sub(i, i), f)
        w = w + (c and f.w[c] + 1 or (f.w[0x20] or 3) + 1)
    end
    return w
end

-- draw text with the top-left corner at x, y; returns the width drawn
function F.draw(f, text, x, y)
    local cx = x
    for i = 1, #text do
        local c = code(text:sub(i, i), f)
        if c then
            love.graphics.draw(f.image, f.quad[c], cx, y)
            cx = cx + f.w[c] + 1
        else
            cx = cx + (f.w[0x20] or 3) + 1
        end
    end
    return cx - x
end

-- split text into lines no wider than maxw
function F.wrap(f, text, maxw)
    local lines, line, lw = {}, "", 0
    for word in text:gmatch("%S+") do
        local ww = F.width(f, word)
        local sp = F.width(f, " ")
        if line ~= "" and lw + sp + ww > maxw then
            lines[#lines + 1] = line; line, lw = word, ww
        else
            if line == "" then line, lw = word, ww else line = line .. " " .. word; lw = lw + sp + ww end
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    if #lines == 0 then lines[1] = "" end
    return lines
end

return F

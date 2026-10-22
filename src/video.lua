-- Display state: BIOS text mode (80x25 in segment B800) or EGA graphics.
local ffi = require("ffi")
local bit = require("bit")
local band, rshift = bit.band, bit.rshift
local vm = require("vm")
local ega = require("ega")

local V = {mode = "text", cursor = {row = 0, col = 0}}
local mem = vm.mem
local font = require("font8x16")

-- CP437 box-drawing and block characters, generated: {up, down, left, right} line styles (0/1 single/2 double)
local BOX = {
    [0xB3] = {1, 1, 0, 0}, [0xB4] = {1, 1, 1, 0}, [0xB5] = {1, 1, 2, 0}, [0xB6] = {2, 2, 1, 0},
    [0xB7] = {0, 2, 1, 0}, [0xB8] = {0, 1, 2, 0}, [0xB9] = {2, 2, 2, 0}, [0xBA] = {2, 2, 0, 0},
    [0xBB] = {0, 2, 2, 0}, [0xBC] = {2, 0, 2, 0}, [0xBD] = {2, 0, 1, 0}, [0xBE] = {1, 0, 2, 0},
    [0xBF] = {0, 1, 1, 0}, [0xC0] = {1, 0, 0, 1}, [0xC1] = {1, 0, 1, 1}, [0xC2] = {0, 1, 1, 1},
    [0xC3] = {1, 1, 0, 1}, [0xC4] = {0, 0, 1, 1}, [0xC5] = {1, 1, 1, 1}, [0xC6] = {1, 1, 0, 2},
    [0xC7] = {2, 2, 0, 1}, [0xC8] = {2, 0, 0, 2}, [0xC9] = {0, 2, 0, 2}, [0xCA] = {2, 0, 2, 2},
    [0xCB] = {0, 2, 2, 2}, [0xCC] = {2, 2, 0, 2}, [0xCD] = {0, 0, 2, 2}, [0xCE] = {2, 2, 2, 2},
    [0xCF] = {1, 0, 2, 2}, [0xD0] = {2, 0, 1, 1}, [0xD1] = {0, 1, 2, 2}, [0xD2] = {0, 2, 1, 1},
    [0xD3] = {2, 0, 0, 1}, [0xD4] = {1, 0, 0, 2}, [0xD5] = {0, 1, 0, 2}, [0xD6] = {0, 2, 0, 1},
    [0xD7] = {2, 2, 1, 1}, [0xD8] = {1, 1, 2, 2}, [0xD9] = {1, 0, 1, 0}, [0xDA] = {0, 1, 0, 1},
}
local function boxglyph(arms)
    local g = {}
    for y = 1, 16 do g[y] = 0 end
    local function setpx(x, y) g[y + 1] = bit.bor(g[y + 1], bit.lshift(1, 7 - x)) end
    local function hline(x0, x1, y) for x = x0, x1 do setpx(x, y) end end
    local function vline(x, y0, y1) for y = y0, y1 do setpx(x, y) end end
    local up, down, left, right = arms[1], arms[2], arms[3], arms[4]
    -- vertical arms: single line at column 3, double at columns 2 and 4 ; horizontal: rows 7 / rows 6 and 8
    local function varm(style, y0, y1)
        if style == 1 then vline(3, y0, y1) elseif style == 2 then vline(2, y0, y1); vline(4, y0, y1) end
    end
    local function harm(style, x0, x1)
        if style == 1 then hline(x0, x1, 7) elseif style == 2 then hline(x0, x1, 6); hline(x0, x1, 8) end
    end
    varm(up, 0, 7); varm(down, 8, 15)
    -- draw the horizontal arms to the centre column(s)
    harm(left, 0, 4); harm(right, 3, 7)
    return g
end
for code, arms in pairs(BOX) do font[code] = boxglyph(arms) end
for _, spec in ipairs{{0xDB, 0xFF, 0xFF}, {0xDC, 0x00, 0xFF}, {0xDF, 0xFF, 0x00}} do
    local g = {}
    for y = 1, 16 do g[y] = (y <= 8) and spec[2] or spec[3] end
    font[spec[1]] = g
end
do
    local g, h = {}, {}
    for y = 1, 16 do g[y] = 0xF0; h[y] = 0x0F end
    font[0xDD] = g; font[0xDE] = h
    local a, b, c = {}, {}, {}
    for y = 1, 16 do
        a[y] = (y % 2 == 1) and 0xAA or 0x00
        b[y] = (y % 2 == 1) and 0xAA or 0x55
        c[y] = (y % 2 == 1) and 0xFF or 0xAA
    end
    font[0xB0], font[0xB1], font[0xB2] = a, b, c
end

-- CGA/EGA text attribute colours
local TEXTPAL = {
    [0] = {0, 0, 0}, {0, 0, 170}, {0, 170, 0}, {0, 170, 170}, {170, 0, 0}, {170, 0, 170},
    {170, 85, 0}, {170, 170, 170}, {85, 85, 85}, {85, 85, 255}, {85, 255, 85}, {85, 255, 255},
    {255, 85, 85}, {255, 85, 255}, {255, 255, 85}, {255, 255, 255},
}

function V.getmode() return V.mode == "graphics" and 0x0D or 3 end

function V.setmode(m)
    local clear = band(m, 0x80) == 0
    m = band(m, 0x7F)
    if m == 0x0D then
        ega.setmode(clear)
        V.mode = "graphics"
    else
        V.mode = "text"
        if clear then
            for i = 0, 80 * 25 - 1 do mem[0xB8000 + i * 2] = 0x20; mem[0xB8000 + i * 2 + 1] = 0x07 end
        end
    end
end

function V.setcursor(row, col) V.cursor.row, V.cursor.col = row, col end

function V.scroll(lines, top, left, bottom, right, attr)
    local base = 0xB8000
    if lines == 0 then lines = bottom - top + 1 end
    for r = top, bottom do
        for c = left, right do
            local dst = base + (r * 80 + c) * 2
            local sr = r + lines
            if sr <= bottom then
                local src = base + (sr * 80 + c) * 2
                mem[dst] = mem[src]; mem[dst + 1] = mem[src + 1]
            else
                mem[dst] = 0x20; mem[dst + 1] = attr
            end
        end
    end
end

-- 640x400 RGBA frame for text mode
function V.render_text(buf)
    for row = 0, 24 do
        for col = 0, 79 do
            local a = 0xB8000 + (row * 80 + col) * 2
            local ch, at = mem[a], mem[a + 1]
            local g = font[ch]
            local fg, bg = TEXTPAL[band(at, 15)], TEXTPAL[band(rshift(at, 4), 7)]
            for y = 0, 15 do
                local bits = g and g[y + 1] or 0
                local o = ((row * 16 + y) * 640 + col * 8) * 4
                for x = 0, 7 do
                    local c = band(bits, bit.lshift(1, 7 - x)) ~= 0 and fg or bg
                    buf[o] = c[1]; buf[o + 1] = c[2]; buf[o + 2] = c[3]; buf[o + 3] = 255
                    o = o + 4
                end
            end
        end
    end
end

return V

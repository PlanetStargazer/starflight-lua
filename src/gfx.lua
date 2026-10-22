-- Graphics primitives of Starflight 1 (EGA path).
--
-- Ported from the machine code in STARFLT.COM (addresses 0x8400..0x9A00) and
-- from the "EGA" driver overlay that the game loads from STARA.COM into a far
-- segment.  The driver is reached through far-call stubs (LPLOT, LLINE, {BLT}
-- ...); here those words are replaced by Lua functions with the same stack
-- effects.  The routines draw through the EGA register model in ega.lua.
--
-- The game's pixel is two EGA pixels wide: 160x200 logical pixels, four to a
-- byte, bit masks C0/30/0C/03.
--
-- Naming follows the original: (y,x) coordinate pairs, "VIN/VOUT" vertex
-- arrays, "OIN/OOUT" outcode arrays, the SCAN table of per-row spans.

local bit = require("bit")
local band, bor, bxor, rshift, lshift = bit.band, bit.bor, bit.bxor, bit.rshift, bit.lshift
local vm = require("vm")
local ega = require("ega")

local rd8, wr8, rd16, wr16 = vm.rd8, vm.wr8, vm.rd16, vm.wr16
local lrd8, lwr8, lrd16, lwr16 = vm.lrd8, vm.lwr8, vm.lrd16, vm.lwr16
local push, pop, def, s16 = vm.push, vm.pop, vm.def, vm.s16

local G = {}
local M16 = 0xFFFF

-- variable addresses (offsets in the data segment)
local COLOR, BUFSEG, YTABL = 0x55F2, 0x5648, 0x563A
local VIN, VOUT, OIN, OOUT = 0x569B, 0x56A6, 0x56B0, 0x56BB
local NIN, NOUT = 0x5686, 0x5691
local TRJCT, TACCPT = 0x56E8, 0x56DC
local ILEFT, IRIGHT, IBELOW, IABOVE = 0x5738, 0x5745, 0x5752, 0x575F
local EGABIT = 0x92CF
local XORMODE = 0x587C
local SCAN, SCANP, ELEMENT, HORIZ = 0x57D9, 0x57E1, 0x57DD, 0x57FB
local YMIN, YMAX, XSTART, XEND, YLINE = 0x57EC, 0x57F7, 0x57B7, 0x57C2, 0x57CE
local P5708, P5704, P5714, P5710 = 0x5708, 0x5704, 0x5714, 0x5710
local P570C, P5718, P5728, P572C, P56CF, OPENF = 0x570C, 0x5718, 0x5728, 0x572C, 0x56CF, 0x56F4
local XBLT, YBLT, WBLT, LBLT, ABLT, BLTSEG, BLTP = 0x586E, 0x5863, 0x5892, 0x5887, 0x589D, 0x58AA, 0x58B5
local ALLF, YOKF, BITS, NBITS = 0x52BE, 0x52C9, 0x601F, 0x602B
local EX, EY, ERAD, XNUMER, XDENOM, ARC1 = 0x5A65, 0x5A6E, 0x5A79, 0x5A86, 0x5A93, 0x5AA0
local ZZZ = 0x48C6

local function setgc(reg, v) ega.out(0x3CE, reg); ega.out(0x3CF, v) end

local function maskof(x) return rd8(EGABIT + band(x, 3) * 2) end
local function rowbase(y) return rd16(band(rd16(YTABL) + band(y, M16) * 2, M16)) end
local function offof(x, y) return band(rowbase(y) + rshift(band(x, M16), 2), M16) end

-- WRITE-DOT: bit mask, set/reset colour, read (latch) then write
local function writedot(seg, off, mask)
    setgc(8, mask)
    setgc(0, rd8(COLOR))
    lrd8(seg, off)
    lwr8(seg, off, 0)
end
local function writexdot(seg, off, mask)       -- WRITE-XDO: same with the XOR function
    setgc(3, 0x18)
    writedot(seg, off, mask)
    setgc(3, 0)
end

-- ---------------------------------------------------------------------------
-- LPLOT ( x y -- ), LXPLOT, SQLPLOT, PLOT, L@PIXEL
-- ---------------------------------------------------------------------------
def(0x9002, function()
    setgc(1, 0x0F)
    local y, x = pop(), pop()
    writedot(rd16(BUFSEG), offof(x, y), maskof(x))
end)
def(0x9017, function()
    setgc(1, 0x0F)
    local y, x = pop(), pop()
    writexdot(rd16(BUFSEG), offof(x, y), maskof(x))
    setgc(8, 0xFF)
end)
def(0x9097, function()                         -- SQLPLOT: two vertically adjacent dots
    setgc(1, 0x0F)
    local y, x = pop(), pop()
    local seg = rd16(BUFSEG)
    writedot(seg, offof(x, y), maskof(x))
    writedot(seg, offof(x, y + 1), maskof(x))
    setgc(8, 0xFF)
end)
def(0x9367, function()                         -- PLOT ( x y -- ): GC already set up by the caller
    local y, x = pop(), pop()
    writedot(rd16(BUFSEG), offof(x, y), maskof(x))
end)
def(0x910F, function()                         -- L@PIXEL ( x y -- colour )
    setgc(7, 0x0F); setgc(5, 0)
    local y, x = pop(), pop()
    local seg, off, mask = rd16(BUFSEG), offof(x, y), maskof(x)
    local c = 0
    for p = 0, 3 do
        setgc(4, p)
        if band(lrd8(seg, off), mask) ~= 0 then c = bor(c, lshift(1, p)) end
    end
    push(c)
end)
def(0x92EF, function() setgc(1, 0x0F) end)          -- S/RON
def(0x937B, function() setgc(0, rd8(COLOR)) end)    -- SETCOLO

-- ---------------------------------------------------------------------------
-- screen / buffer level words
-- ---------------------------------------------------------------------------
def(0x8F8B, function()                         -- BFILL: fill the whole buffer with COLOR
    if band(rd16(0x5DA3), 0xFF) ~= 0 then
        ega.out(0x3C4, 2); ega.out(0x3C5, 0x0F)
        setgc(1, 0x0F); setgc(0, rd8(COLOR)); setgc(8, 0xFF)
        local seg, n = rd16(BUFSEG), rd16(0x5656)
        for i = 0, n - 1 do lwr8(seg, i, 0) end
    else
        local seg, n, c = rd16(BUFSEG), rshift(rd16(0x5656), 1), rd8(COLOR)
        for i = 0, n - 1 do lwr16(seg, i * 2, c * 257) end
    end
end)
def(0x8E4F, function()                         -- W8E4F ( ds si es di -- ): 0x2000 bytes page copy
    local di, es, si, ds = pop(), pop(), pop(), pop()
    setgc(5, 1)                                -- write mode 1: latch copy
    for i = 0, 0x1FFF do lwr8(es, di + i, lrd8(ds, si + i)) end
    setgc(5, 0)
end)
def(0x8D09, function() end)                    -- DISPLAY-WAIT (vertical retrace)
def(0x8D66, function() pop() end)              -- W8D66: stores the equipment word at 0040:0010
def(0x8D8B, function()                         -- >LORES: 320x200x16 graphics
    require("video").setmode(0x8D)
    setgc(1, 0x0F)
end)
def(0x8DF0, function()                         -- >ALPHACODE: back to text mode
    require("video").setmode(2)
end)
def(0x6C86, function()                         -- C>EGA ( colour -- ega colour )
    local dx = band(pop(), 0xF)
    local found = 0
    for k = 0, 15 do                           -- scans table 0x4FCA downwards, first hit wins
        if band(rd8(0x4FCA - k), 0xF) == dx then found = 16 - k; break end
    end
    push(rd8(0x4FCC + found))
end)

def(0x6CD6, function()                         -- E>CGA ( colour -- cga colour )
    local dx = band(pop(), 0xF)
    local found = 0
    for k = 0, 15 do
        if band(rd8(0x4FDC - k), 0xF) == dx then found = 16 - k; break end
    end
    push(rd8(0x4FBA + found))
end)

-- ---------------------------------------------------------------------------
-- outcodes and polygon clipping
-- ---------------------------------------------------------------------------
local function treject()                       -- TREJECT/TACCEPT (0x8538)
    local bl, bh = 0x0F, 0
    local si, di = rd16(VIN), rd16(OIN)
    local below, above, left, right = s16(rd16(IBELOW)), s16(rd16(IABOVE)), s16(rd16(ILEFT)), s16(rd16(IRIGHT))
    for i = 0, rd16(NIN) - 1 do
        local y, x = s16(rd16(si + i * 4)), s16(rd16(si + i * 4 + 2))
        local dx = 0
        if y < below then dx = bor(dx, 4) end
        if y > above then dx = bor(dx, 8) end
        if x < left then dx = bor(dx, 1) end
        if x > right then dx = bor(dx, 2) end
        wr8(di + i, dx)
        bl = band(bl, dx); bh = bor(bh, dx)
    end
    wr16(TRJCT, bl); wr16(TACCPT, bh)
end
def(0x8538, treject)
def(0x9390, function()                         -- ?EXTENTX ( 4 values -- ): clip codes of a 2-point box
    local vin = rd16(VIN)
    for i = 0, 3 do wr16(vin + i * 2, pop()) end
    wr16(NIN, 2)
    treject()
end)

local function intersect()                     -- INT/O (0x8596) -> dx(y), cx(x), outcode
    local cx, si, bp, di = rd16(P5710), rd16(P5714), rd16(P5704), rd16(P5708)
    local flag = rd16(P56CF)
    if flag == 1 then cx, si = si, cx; bp, di = di, bp end
    local ax = s16(rd16(P572C)) - s16(cx)
    local bx = s16(di) - s16(si)
    local prod = ax * bx
    local div = s16(bp) - s16(cx)
    local q = prod / div
    q = q < 0 and math.ceil(q) or math.floor(q)
    local dx = band(q + s16(si), M16)
    cx = rd16(P572C)
    if flag == 1 then cx, dx = dx, cx end
    local code = 0
    if s16(cx) < s16(rd16(ILEFT)) then code = bor(code, 1) end
    if s16(cx) > s16(rd16(IRIGHT)) then code = bor(code, 2) end
    if s16(dx) < s16(rd16(IBELOW)) then code = bor(code, 4) end
    if s16(dx) > s16(rd16(IABOVE)) then code = bor(code, 8) end
    return dx, cx, code
end

local function clip()                          -- CLIP (0x8605): clip against one boundary; returns #OUT
    wr16(NOUT, 0)
    local si, di, bx, bp = rd16(VIN), rd16(VOUT), rd16(OIN), rd16(OOUT)
    local cx = rd16(NIN)
    local mask = rd16(P5728)
    local open = rd16(OPENF) == 1
    local function emit(code)                  -- movsw movsw ; store code
        wr16(di, rd16(si)); wr16(di + 2, rd16(si + 2))
        di = di + 4; si = si + 4
        wr8(bp, code); bp = bp + 1
        wr16(NOUT, rd16(NOUT) + 1)
    end
    if open then
        wr16(P5708, rd16(si)); wr16(P5704, rd16(si + 2))
        local al = rd8(bx); wr8(P570C, al)
        if band(al, band(mask, 0xFF)) == 0 then emit(al) else si = si + 4 end
        cx = cx - 1; bx = bx + 1
    else
        cx = cx - 1
        wr8(P570C, rd8(bx + cx))
        wr16(P5708, rd16(si + cx * 4)); wr16(P5704, rd16(si + cx * 4 + 2))
        cx = cx + 1
    end
    while true do
        wr16(P5714, rd16(si)); wr16(P5710, rd16(si + 2))
        local cur = rd8(bx); wr8(P5718, cur)
        bx = bx + 1
        local al = band(band(mask, 0xFF), cur)
        local ah = band(rshift(mask, 8), rd8(P570C))
        if ah ~= al then
            local c = 0
            local line = rd16(P572C)
            if rd16(P56CF) == 0 then
                if line ~= rd16(P5710) then c = 1 end
                if line == rd16(P5704) then c = 0 else c = band(c, 1) end
            else
                if line ~= rd16(P5714) then c = 1 end
                if line == rd16(P5708) then c = 0 else c = band(c, 1) end
            end
            if open then c = c + 1 end
            if c ~= 0 then
                local dx, xx, code = intersect()
                wr16(di, dx); wr16(di + 2, xx); di = di + 4
                wr16(bp, code); bp = bp + 1                  -- the original stores AX: the high byte spills into the next slot
                wr16(NOUT, rd16(NOUT) + 1)
            end
        end
        if al == 0 then emit(rd8(P5718)) else si = si + 4 end
        wr16(P5708, rd16(P5714)); wr16(P5704, rd16(P5710)); wr8(P570C, rd8(P5718))
        cx = cx - 1
        if cx == 0 then break end
    end
    local a, b = rd16(VIN), rd16(VOUT); wr16(VOUT, a); wr16(VIN, b)
    a, b = rd16(OIN), rd16(OOUT); wr16(OOUT, a); wr16(OIN, b)
    wr16(NIN, rd16(NOUT))
    return rd16(NOUT)
end

def(0x8783, function()                         -- CLIPPER
    treject()
    if rd16(TRJCT) ~= 0 then wr16(NIN, 0); return end
    local ax = rd16(TACCPT)
    if ax == 0 then return end
    local di = 0x5253
    local cx = 4
    while cx > 0 do
        local dx = rd16(di)
        if band(dx, 0xFF) ~= 0 and band(band(dx, 0xFF), band(ax, 0xFF)) ~= 0 then
            wr16(P5728, dx)
            wr16(P56CF, rd8(di + 2))
            wr16(P572C, rd16(di + 3))
            local n = clip()
            if n == 0 then cx = 1 end
            di = di + 5
        else
            di = di + 5
        end
        cx = cx - 1
    end
end)

-- ---------------------------------------------------------------------------
-- polygon scan conversion
-- ---------------------------------------------------------------------------
local function scancon()                       -- SCANCON (0x87E1): one edge into the SCAN table
    local save14, save10 = rd16(P5714), rd16(P5710)
    local y0, y1 = rd16(P5708), rd16(P5714)
    if s16(band(y1 - y0, M16)) < 0 then        -- swap so that y0 <= y1
        wr16(P5708, y1); wr16(P5714, y0)
        local cx = rd16(P5704)
        local ax = rd16(P5710)
        wr16(P5704, ax); wr16(P5710, cx)
    end
    local bl = 0xC3                            -- opcode selecting INC BL
    local ax = s16(rd16(P5710)) - s16(rd16(P5704))
    if ax < 0 then bl = 0xCB; ax = -ax end
    local cx = ax
    local bh = 0xC7                            -- INC BH
    ax = s16(rd16(P5714)) - s16(rd16(P5708))
    local dx = ax
    if dx < cx then dx, cx = cx, dx; bh, bl = bl, bh end   -- dx = major axis length, cx = minor
    local x = band(rd16(P5704), 0xFF)          -- bl
    local y = band(rd16(P5708), 0xFF)          -- bh
    local minor, half, major = cx, rshift(cx, 1), dx
    local scanp = rd16(SCANP)
    local acc = 0
    local function step(opc)
        if opc == 0xC3 then x = band(x + 1, 0xFF)
        elseif opc == 0xCB then x = band(x - 1, 0xFF)
        elseif opc == 0xC7 then y = band(y + 1, 0xFF)
        elseif opc == 0xCF then y = band(y - 1, 0xFF) end
    end
    -- the patched "major" step opcode is the one held in bh, the "minor" one in bl
    local majop, minop = bh, bl
    repeat
        wr8(scanp + y * 2, x)
        step(majop)
        acc = acc + minor
        if acc > half then acc = acc - major; step(minop) end
        dx = dx - 1
    until dx < 0
    wr16(P5714, save14); wr16(P5710, save10)
end

def(0x8891, function()                         -- SCANPOLY: fill the SCAN table from the VIN polygon
    wr16(HORIZ, 0); wr16(ELEMENT, 0)
    local n = rd16(NIN)
    local vin = rd16(VIN)
    local di = vin + (n - 1) * 4
    wr16(P5708, rd16(di)); wr16(P5704, rd16(di + 2))
    wr16(YMIN, rd16(vin)); wr16(YMAX, rd16(vin))
    local cx = n
    di = vin
    local stack = {}
    while true do
        local ax = rd16(di)
        wr16(P5714, ax)
        local bx = rd16(di + 2)
        wr16(P5710, bx)
        di = di + 4
        local dx = rd16(P5708)
        if ax == dx then
            wr16(HORIZ, rd16(HORIZ) + 1)
            local px = rd16(P5704)
            if s16(bx) - s16(px) >= 0 then
                stack[#stack + 1] = bx; stack[#stack + 1] = px
            else
                stack[#stack + 1] = px; stack[#stack + 1] = bx
            end
            stack[#stack + 1] = ax
        else
            if s16(rd16(YMIN)) > s16(ax) then wr16(YMIN, ax)
            elseif s16(rd16(YMAX)) < s16(ax) then wr16(YMAX, ax) end
            dx = (s16(rd16(P5708)) > s16(ax)) and 1 or 0
            wr16(ELEMENT, dx)
            wr16(SCANP, rd16(SCAN) + dx)
            scancon()
        end
        wr16(P5708, rd16(P5714)); wr16(P5704, rd16(P5710))
        cx = cx - 1
        if cx == 0 then break end
    end
    local horiz = rd16(HORIZ)
    if horiz > 0 then
        wr16(P5708, 0x0900)
        for _ = 1, horiz do
            local y = table.remove(stack)
            local d = rd16(SCAN) + y * 2
            if y == rd16(P5708) then
                local al = table.remove(stack)
                if vm.s8(al) < vm.s8(rd8(d)) then wr8(d, al) end
                d = d + 1
                al = table.remove(stack)
                if vm.s8(al) > vm.s8(rd8(d)) then wr8(d, al) end
            else
                wr16(P5708, y)
                wr8(d, table.remove(stack))
                d = d + 1
                wr8(d, table.remove(stack))
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- spans, polygon fill, tiles
-- ---------------------------------------------------------------------------
local function fillspan(seg, rowoff, x0, x1)    -- pixels x0..x1 inclusive on the row at byte offset rowoff
    local x = x0
    while x <= x1 and band(x, 3) ~= 0 do          -- leading single pixels up to a byte boundary
        writedot(seg, band(rowoff + rshift(x, 2), M16), maskof(x)); x = x + 1
    end
    if x + 3 <= x1 then                           -- whole bytes (four game pixels each)
        setgc(8, 0xFF); setgc(0, rd8(COLOR))
        while x + 3 <= x1 do
            local off = band(rowoff + rshift(x, 2), M16)
            lrd8(seg, off); lwr8(seg, off, 0)
            x = x + 4
        end
    end
    while x <= x1 do                              -- trailing single pixels
        writedot(seg, band(rowoff + rshift(x, 2), M16), maskof(x)); x = x + 1
    end
    setgc(8, 0xFF)
end

-- FVLINE (driver entry 0x4FB): horizontal span XSTART..XEND on row YLINE, drawn into BUF-SEG
local function fvline()
    local xend = rd16(XEND)
    if xend > rd16(IRIGHT) then return end
    local xs = rd16(XSTART)
    if xs > xend then return end
    fillspan(rd16(BUFSEG), rowbase(rd16(YLINE)), xs, xend)
end
G.fvline = fvline
def(0x9125, function() fvline() end)           -- the stub word, in case Forth code executes it

def(0x9055, function()                         -- LFILLPOLY: fill the rows described by SCAN
    local scan = rd16(SCAN)
    local ymin, ymax = rd16(YMIN), rd16(YMAX)
    local mid = band(rshift(ymin + ymax + 1, 1) * 2, M16) + scan
    if rd8(mid + 1) < rd8(mid) then return end -- degenerate polygon
    setgc(1, 0x0F)
    setgc(8, 0xFF)
    setgc(0, rd8(COLOR))
    wr16(YMAX, ymax + 1)
    for y = ymin, ymax do
        wr16(XSTART, rd8(scan + y * 2)); wr16(XEND, rd8(scan + y * 2 + 1)); wr16(YLINE, y)
        fvline()
    end
    wr16(YMAX, ymax)
end)

def(0x9081, function()                         -- TILEFILL ( x y w h -- )
    setgc(1, 0x0F)
    local w, h, y, x = pop(), pop(), pop(), pop()
    local oldcolor = rd16(COLOR)
    local tile = rd16(rd16(0x58CD))            -- TILE-PTR -> word
    wr16(COLOR, tile)
    setgc(0, rd8(COLOR))
    local seg = rd16(BUFSEG)
    local yl = band(y - h + 1, M16)
    if w == 8 then
        local off = band(rowbase(yl) + rshift(x, 2), M16)
        setgc(8, 0xFF)
        for _ = 1, h do
            lrd8(seg, off); lwr8(seg, off, 0)
            lrd8(seg, off + 1); lwr8(seg, off + 1, 0)
            off = off + 0x12
        end
    else
        local xs = band(x, 0xFE)
        local xe = xs + w - 1
        for _ = 1, h do
            wr16(XSTART, xs); wr16(XEND, xe); wr16(YLINE, yl)
            fvline()
            yl = yl + 1
        end
    end
    wr16(COLOR, oldcolor)
end)

-- ---------------------------------------------------------------------------
-- bitmap blit {BLT}
-- ---------------------------------------------------------------------------
def(0x902B, function()
    -- ALLWITHIN: is the whole bitmap inside the clip window?
    local x, w, y, l = s16(rd16(XBLT)), rd16(WBLT), s16(rd16(YBLT)), rd16(LBLT)
    local all = 0
    if x >= s16(rd16(ILEFT)) and x + w - 1 <= s16(rd16(IRIGHT)) and y <= s16(rd16(IABOVE)) and
       y - l + 1 >= s16(rd16(IBELOW)) then all = 0xFF end
    wr16(ALLF, all)
    local seg = rd16(BUFSEG)
    setgc(1, 0x0F)
    wr16(BLTP, rd16(ABLT))
    local bseg = rd16(BLTSEG)
    local function nextword()
        local v = lrd16(bseg, rd16(BLTP))
        wr16(BLTP, rd16(BLTP) + 2)
        wr16(NBITS, 16); wr16(BITS, v)
    end
    nextword()
    local function bitset()                    -- ?BITSET
        wr16(NBITS, band(rd16(NBITS) - 1, M16))
        local b = rd16(BITS)
        wr16(BITS, band(b * 2, M16))
        return b >= 0x8000
    end
    local xor = rd16(XORMODE) ~= 0
    local ileft, iright, ibelow, iabove = rd16(ILEFT), rd16(IRIGHT), rd16(IBELOW), rd16(IABOVE)
    local rows, cols = l, w
    for r = 0, rows - 1 do
        local yy = band(y - r, M16)
        wr16(YLINE, rowbase(yy))
        local yok
        if band(all, 1) ~= 0 then yok = true else yok = (yy <= iabove and yy >= ibelow) end
        for c = 0, cols - 1 do
            local xx = band(x + c, M16)
            if yok then
                local xok = band(all, 1) ~= 0 or (xx <= iright and xx >= ileft)
                if xok then
                    if bitset() then
                        local off = band(rd16(YLINE) + rshift(xx, 2), M16)
                        if not xor then
                            writedot(seg, off, maskof(xx))
                        else
                            writexdot(seg, off, maskof(xx))
                            setgc(8, 0xFF)
                        end
                    end
                else
                    bitset()
                end
            else
                bitset()
            end
            if band(rd16(NBITS), 0xF) == 0 then nextword() end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- LLINE ( x2 y2 x1 y1 -- )
-- ---------------------------------------------------------------------------
def(0x903F, function()
    setgc(1, 0x0F)
    local y1, x1, y2, x2 = pop(), pop(), pop(), pop()
    local bl, bh = 0xC3, 0xC7
    local ax = s16(x2) - s16(x1)
    if ax < 0 then bl = 0xCB; ax = -ax end
    local cx = ax
    ax = s16(y2) - s16(y1)
    if ax < 0 then bh = 0xCF; ax = -ax end
    local dx = ax
    if dx < cx then dx, cx = cx, dx; bh, bl = bl, bh end
    local major, minor, half = dx, cx, rshift(cx, 1)
    local x, y = band(x1, 0xFF), band(y1, 0xFF)
    local seg = rd16(BUFSEG)
    local function step(opc)
        if opc == 0xC3 then x = band(x + 1, 0xFF)
        elseif opc == 0xCB then x = band(x - 1, 0xFF)
        elseif opc == 0xC7 then y = band(y + 1, 0xFF)
        else y = band(y - 1, 0xFF) end
    end
    setgc(0, rd8(COLOR))
    local acc = 0
    for _ = 0, dx do
        writedot(seg, band(rowbase(y) + rshift(x, 2), M16), maskof(x))
        step(bh)
        acc = acc + minor
        if acc > half then acc = acc - major; step(bl) end
    end
    setgc(8, 0xFF)
end)

-- ---------------------------------------------------------------------------
-- LCOPYBLK ( 6 values ): copy a rectangle inside the video buffer using latches
-- ---------------------------------------------------------------------------
def(0x906B, function()
    local s0, s1, s2, s3, s4, s5 = pop(), pop(), pop(), pop(), pop(), pop()
    local ytab = rd16(YTABL)
    local cx = band(s4 - s2, M16)
    local ax, dx, di = s0, s4, 0
    if s16(band(dx - ax, M16)) < 0 then
        di = 0xFFFF
    else
        ax = band(ax - cx, M16); dx = band(dx - cx, M16); di = 1
    end
    local ysrcslot, ydstslot = ax, dx           -- [bx+4], [bx+8]
    local xfirst, xsecond = s5, s1               -- offsets copied from / to (see PLMOV)
    local cols = band(rshift(band(s3 - s5, M16), 2) + 1, M16)
    local rows = band(cx + 1, M16)
    local seg = rd16(BUFSEG)
    local step = s16(di)
    for _ = 1, rows do
        local a = band(rd16(ytab + ydstslot * 2) + rshift(xfirst, 2), M16)       -- si
        ydstslot = band(ydstslot + step, M16)
        local b = band(rd16(ytab + ysrcslot * 2) + rshift(xsecond, 2), M16)      -- di
        ysrcslot = band(ysrcslot + step, M16)
        setgc(5, 1)
        if s16(b) > s16(a) then
            for k = cols - 1, 0, -1 do lwr8(seg, b + k, lrd8(seg, a + k)) end
        else
            for k = 0, cols - 1 do lwr8(seg, b + k, lrd8(seg, a + k)) end
        end
        setgc(5, 0)
    end
end)

-- V>DISPLAY: copy the 18x120-byte view buffer into the visible page
def(0x90AD, function()
    local dseg, hseg = rd16(0x55E6), rd16(0x55D8)       -- DBUF-SEG, HBUF-SEG
    local tab = 0x6598
    local si = 0
    setgc(5, 1)
    for _ = 1, 0x78 do
        local di = band(rd16(tab) + 1, M16)
        for k = 0, 0x11 do lwr8(dseg, di + k, lrd8(hseg, si + k)) end
        si = si + 0x12
        tab = tab + 2
    end
    setgc(5, 0)
end)

-- ---------------------------------------------------------------------------
-- ellipses
-- ---------------------------------------------------------------------------
local function xasp(v)                          -- scale by XNUMER/XDENOM
    local prod = s16(v) * s16(rd16(XNUMER))
    local d = s16(rd16(XDENOM))
    local q = prod / d
    return band(q < 0 and math.ceil(q) or math.floor(q), M16)
end

def(0x90C3, function()                          -- EEXTENT ( -- x1 y1 x2 y2 )
    local ax = rd16(ERAD)
    local dx = ax
    ax = xasp(ax)
    local ex, ey = rd16(EX), rd16(EY)
    push(band(ex - ax, M16)); push(band(ey - dx, M16))
    push(band(ex + ax, M16)); push(band(ey + dx, M16))
end)

local function plot4(ax, dx)                    -- 0xAA6: one clipped dot at (EX+ax, EY+dx)
    dx = band(dx + rd16(EY), M16); ax = band(ax + rd16(EX), M16)
    local vin = rd16(VIN)
    wr16(vin, dx); wr16(vin + 2, ax)
    wr16(NIN, 1)
    treject()
    if rd16(TACCPT) == 0 then
        writedot(rd16(BUFSEG), offof(ax, dx), maskof(ax))
    end
end
local function ellip_point(ax, dx)              -- 0xB20 : four symmetric dots
    ax = xasp(ax)
    plot4(ax, dx)
    plot4(band(-ax, M16), dx)
    plot4(band(-ax, M16), band(-dx, M16))
    plot4(ax, band(-dx, M16))
end
local function ellip_cb(ax, dx)                 -- {.ELLIP} callback (0xC01)
    ellip_point(ax, dx)
    ellip_point(dx, ax)
end
local function scan_row(ax, dx)                 -- 0xB53: left/right span for rows EY +- dx
    ax = xasp(ax)
    local ex, ey = s16(rd16(EX)), s16(rd16(EY))
    local ileft, iright = s16(rd16(ILEFT)), s16(rd16(IRIGHT))
    local below, above = s16(rd16(IBELOW)), s16(rd16(IABOVE))
    local bx = ex + s16(ax)
    if bx > iright then bx = iright end
    if bx < ileft then bx = ileft - 1 end
    local right = band(bx, 0xFF)
    bx = ex - s16(ax)
    if bx < ileft then bx = ileft end
    local left
    if bx > iright then left = band(right + 1, 0xFF) else left = band(bx, 0xFF) end
    local d = s16(dx)
    local scan = rd16(SCAN)
    local cx = ey + d
    if not (cx > above or cx < below) then wr8(scan + cx * 2, left); wr8(scan + cx * 2 + 1, right) end
    cx = ey - d
    if not (cx < below or cx > above) then wr8(scan + cx * 2, left); wr8(scan + cx * 2 + 1, right) end
end
local function scanellip_cb(ax, dx)             -- .{SCANELLIP} callback (0xBE7)
    scan_row(ax, dx)
    scan_row(dx, ax)
end
G.OFF_ELLIP, G.OFF_SCANELLIP = 0x0C01, 0x0BE7

def(0x90F9, function()                          -- ARC: midpoint circle driving the <ARC1> callback
    setgc(1, 0x0F)
    local cb = rd16(ARC1)
    local fn = (cb == G.OFF_SCANELLIP) and scanellip_cb or ellip_cb
    local dx = rd16(ERAD)
    local ax = 0
    local cx = band(3 - dx * 2, M16)
    while s16(ax) - s16(dx) < 0 do
        fn(ax, dx)
        if s16(cx) < 0 then
            cx = band(cx + 6 + ax * 4, M16)
        else
            cx = band(cx + 10 + (ax - dx) * 4, M16)
            dx = dx - 1
        end
        ax = ax + 1
    end
    if dx == ax then fn(ax, dx) end
end)

-- ---------------------------------------------------------------------------
-- small graphics helpers living in the main binary
-- ---------------------------------------------------------------------------
def(0x8A2D, function()                          -- W8A2D: CGA scan-line address ( y x -- addr )
    local ax = rshift(pop(), 1)
    local bx = band(0xC7 - pop(), M16)
    if band(bx, 1) ~= 0 then ax = ax + 0x2000; bx = band(bx, 0xFFFE) end
    push(band(bx * 0x28 + ax, M16))
end)
-- ---------------------------------------------------------------------------
def(0x93B1, function()                          -- BEXTENT ( -- x y' x' y )
    local x, y, l, w = rd16(XBLT), rd16(YBLT), rd16(LBLT), rd16(WBLT)
    push(x); push(band(y - l + 1, M16)); push(band(x + w - 1, M16)); push(y)
end)
def(0x97CC, function()                          -- COLORMAP ( value -- )
    local bx = pop()
    if bx >= 0x8000 then bx = 0 else bx = band(rshift(bx, 1), 0x38) end
    bx = bx + 0x6A3F
    wr16(0x58CD, bx)                            -- TILE-PTR
    wr16(COLOR, rd8(bx))
    wr16(0x55FF, rd8(bx + 2))                   -- DCOLOR
end)
def(0x9841, function()                          -- BUFFERXY ( x y xshift yshift -- bx dx )
    local cx, ax, dx, bx = pop(), pop(), pop(), pop()
    dx = band(dx - rd16(0x4E53) + 1, M16)
    if cx ~= 0 then dx = band(lshift(dx, cx), M16) end
    dx = band(dx + rd16(0x596B) - 1, M16)
    bx = band(bx - rd16(0x4E49), M16)
    if ax ~= 0 then bx = band(lshift(bx, ax), M16) end
    bx = band(bx + rd16(0x595D), M16)
    push(bx); push(dx)
end)
def(0x992D, function()                          -- ?INVIS ( x y -- flag )
    local ax = 0
    local dx = pop()
    if s16(dx) < s16(rd16(0x5B31)) then ax = bor(ax, 4) end
    if s16(dx) > s16(rd16(0x5B22)) then ax = bor(ax, 8) end
    dx = pop()
    if s16(dx) < s16(rd16(0x5B3C)) then ax = bor(ax, 1) end
    if s16(dx) > s16(rd16(0x5B26)) then ax = bor(ax, 2) end
    push(ax == 0 and 1 or 0)
end)
def(0x9970, function()                          -- WLD>SCR ( x y -- sx sy )
    local function scale(v, vis, num, den, dest)
        local p = s16(band(v - rd16(vis), M16)) * s16(rd16(num))
        local q = p / s16(rd16(den))
        q = q < 0 and math.ceil(q) or math.floor(q)
        return band(q + rd16(dest), M16)
    end
    local y = pop()
    local sy = scale(y, 0x5B31, 0x6221, 0x6223, 0x596B)
    local x = pop()
    local sx = scale(x, 0x5B3C, 0x6211, 0x6213, 0x595D)
    push(sx); push(sy)
end)
def(0x99B4, function()                          -- SCR>BLT
    local y = band(pop() + 7 - rd16(0x5A4E), M16)
    local x = band(pop() - rd16(0x5A4E), M16)
    push(x); push(y)
end)
def(0x95BE, function()                          -- SHL-BIT ( cx ax -- cx' ) rotate bit in
    local ax, cx = pop(), pop()
    push(band(cx * 2 + band(ax, 1), M16))
end)

-- icon table accessors (far arrays of words/bytes indexed by IINDEX)
def(0x9A6C, function() local seg = pop(); push(lrd16(seg, rd16(0x5A02) * 2)) end)       -- @IW
def(0x9A82, function() local seg = pop(); push(lrd8(seg, rd16(0x5A02))) end)            -- W9A82 (@IB)
def(0x9A9E, function() local seg, v = pop(), pop(); lwr16(seg, rd16(0x5A02) * 2, v) end) -- !IW
def(0x9ABA, function() local seg, v = pop(), pop(); lwr8(seg, rd16(0x5A02), v) end)      -- !IB

local function lxchg16(es, a, b)
    local x, y = lrd16(es, a), lrd16(es, b); lwr16(es, a, y); lwr16(es, b, x)
end
local function lxchg8(es, a, b)
    local x, y = lrd8(es, a), lrd8(es, b); lwr8(es, a, y); lwr8(es, b, x)
end
def(0x9E14, function()                          -- XCHGICON ( a b -- )
    local ax, bx = pop(), pop()
    lxchg8(rd16(0x59C6), bx, ax)                -- IDSEG
    lxchg8(rd16(0x59CA), bx, ax)                -- ICSEG
    lxchg8(rd16(0x59DA), bx, ax)                -- IHSEG
    ax = ax * 2; bx = bx * 2
    lxchg16(rd16(0x59BE), bx, ax)               -- IXSEG
    lxchg16(rd16(0x59C2), bx, ax)               -- IYSEG
    lxchg16(rd16(0x59CE), bx, ax)               -- ILSEG
end)
def(0x9D18, function()                          -- ?ILOCUS
    local cx = pop()
    wr16(0x5B04, pop()); wr16(0x5B00, pop()); wr16(0x5AFC, pop()); wr16(0x5AF8, pop())
    local count = 0
    local results = {}
    local radius = s16(rd16(0x5B00))
    while s16(cx) > 0 do
        local bx = (cx - 1 + rd16(0x5B04)) * 2
        local dx = s16(lrd16(rd16(0x59BE), bx)) - s16(rd16(0x5AF8))
        if dx < 0 then dx = -dx end
        if not (dx > radius) then
            dx = s16(lrd16(rd16(0x59C2), bx)) - s16(rd16(0x5AFC))
            if dx < 0 then dx = -dx end
            if not (dx > radius) then
                results[#results + 1] = rshift(bx, 1)
                count = count + 1
            end
        end
        cx = cx - 1
    end
    for _, r in ipairs(results) do push(r) end
    push(count)
end)
def(0x9EB1, function()                          -- ?IID
    local cx = pop()
    wr16(0x5B04, pop())
    local dx = pop()
    wr16(ZZZ + 2, pop())
    local seg = rd16(0x59C6)
    local count = 0
    local results = {}
    while s16(cx) > 0 do
        local bx = cx - 1 + rd16(0x5B04)
        local al = lrd8(seg, bx)
        if s16(al) - s16(dx) < 0 and s16(al) - s16(rd16(ZZZ + 2)) > 0 then
            results[#results + 1] = bx
            count = count + 1
        end
        cx = cx - 1
    end
    for _, r in ipairs(results) do push(r) end
    push(count)
end)

return G

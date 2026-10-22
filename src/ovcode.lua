-- Machine-code words that live inside overlays.  Overlays are loaded at
-- fixed addresses and share the same address range, so a code word is
-- identified by (overlay, address).  The current overlay is the value of OV#
-- (0x55A5), which is the directory start address divided by 16.

local bit = require("bit")
local band, bor, bxor, rshift, lshift, arshift = bit.band, bit.bor, bit.bxor, bit.rshift, bit.lshift, bit.arshift
local vm = require("vm")
local gfx = require("gfx")

local rd8, wr8, rd16, wr16 = vm.rd8, vm.wr8, vm.rd16, vm.wr16
local lrd8, lrd16, lwr8, lwr16 = vm.lrd8, vm.lrd16, vm.lwr8, vm.lwr16
local push, pop, s16 = vm.push, vm.pop, vm.s16

local OV = {
    FRACT = 0x6E3C, SITE = 0x6F92, BLT = 0x714C, PORTMENU = 0x7660,
    MOVE = 0x7FB7, ORBIT = 0x8186, GAME = 0x8F71, MAPS = 0x9179,
}
local OVA = 0x55A5

local registry = {}            -- code address -> { [ov] = fn }

local function def(ov, addr, fn)
    local entry = registry[addr]
    if not entry then
        entry = {}
        registry[addr] = entry
        vm.def(addr, function(bx)
            local f = entry[rd16(OVA)]
            if f then return f(bx) end
            error(string.format("overlay code word %04X not available in overlay %04X", addr, rd16(OVA)))
        end)
    end
    entry[OV[ov]] = fn
end

local G = {def = def}

-- ---------------------------------------------------------------------------
-- BLT-OV: .EGARUNBIT ( seg off -- ): run-length coded bitmap, alternating
-- coloured and transparent runs, drawn row after row inside the BLT window
-- ---------------------------------------------------------------------------
local X1, Y1, X2 = 0x561C, 0x5613, 0x562E
local COLOR, XBLT, YBLT, WBLT = 0x55F2, 0x586E, 0x5863, 0x5892
local XSTART, XEND, YLINE = 0x57B7, 0x57C2, 0x57CE
local BRIGHT, TEMP2 = 0xF35C, 0xF368

def("BLT", 0xF379, function()
    local off, seg = pop(), pop()
    require("ega").out(0x3CE, 0); require("ega").out(0x3CF, rd8(COLOR))
    wr16(X1, rd16(XBLT))
    local bright = band(rd16(XBLT) + rd16(WBLT) - 1, 0xFFFF)
    wr16(BRIGHT, bright)
    wr16(Y1, rd16(YBLT))
    local runs = lrd16(seg, off)
    wr16(TEMP2, runs)
    for i = 0, runs - 1 do
        local len = lrd8(seg, off + i + 2)
        if len ~= 0 then
            local x2 = band(rd16(X1) + len - 1, 0xFFFF)
            wr16(X2, x2)
            while x2 > bright do
                if band(i, 1) == 0 then
                    wr16(XSTART, rd16(X1)); wr16(XEND, bright); wr16(YLINE, rd16(Y1))
                    gfx.fvline()
                end
                x2 = band(x2 - rd16(WBLT), 0xFFFF)
                wr16(X2, x2)
                wr16(X1, rd16(XBLT))
                wr16(Y1, band(rd16(Y1) - 1, 0xFFFF))
            end
            if band(i, 1) == 0 then
                wr16(XSTART, rd16(X1)); wr16(XEND, x2); wr16(YLINE, rd16(Y1))
                gfx.fvline()
            end
            wr16(X1, band(x2 + 1, 0xFFFF))
        end
    end
end)

-- ---------------------------------------------------------------------------
-- SITE-OV / PORTMENU-OV:  |EGA ( flag -- ) copies a strip of the picture between
-- the two video pages with the latch copy (COPYLIN); (|REGION) saves/restores
-- a screen region to/from a buffer segment
-- ---------------------------------------------------------------------------
local ega = require("ega")
local function copypages(flag, startrow, count)
    local dseg, hseg = rd16(0x55E6), rd16(0x55D8)           -- DBUF-SEG, HBUF-SEG
    local es, ds = dseg, hseg
    if band(flag, 1) == 0 then es, ds = ds, es end
    local si = rd16(band(rd16(0x563A) + startrow * 2, 0xFFFF))
    ega.out(0x3CE, 5); ega.out(0x3CF, 1)
    for i = 0, count - 1 do lwr8(es, si + i, lrd8(ds, si + i)) end
    ega.out(0x3CE, 5); ega.out(0x3CF, 0)
end
def("PORTMENU", 0xEC7D, function() local flag = pop(); copypages(flag, band(rd16(0xEBFC) + 3, 0xFFFF), 0x2D0) end)
def("SITE", 0xF0C1, function() local flag = pop(); copypages(flag, 0xC5, 0xA28) end)

local function region()
    wr16(X1, pop())
    local seg = pop()
    local words = rshift(rd16(WBLT), 2) + 2
    local bp = rshift(rd16(XBLT), 1)
    local di = 0
    local bufseg = rd16(0x5648)
    local rows = rd16(0x5887)
    for cx = rows, 1, -1 do
        local si = band(rd16(band(rd16(0x563A) + band(rd16(YBLT) - cx + 1, 0xFFFF) * 2, 0xFFFF)) + bp, 0xFFFF)
        if rd16(X1) == 0 then
            for k = 0, words - 1 do lwr16(seg, di + k * 2, lrd16(bufseg, si + k * 2)) end
        else
            for k = 0, words - 1 do lwr16(bufseg, si + k * 2, lrd16(seg, di + k * 2)) end
        end
        di = di + words * 2
    end
end
def("PORTMENU", 0xEC0C, region)
def("SITE", 0xF050, region)

-- ---------------------------------------------------------------------------
-- FRACT-OV: planet terrain by recursive midpoint displacement
-- ---------------------------------------------------------------------------
local M16 = 0xFFFF
local function idiv16(num, den)           -- signed 32/16 divide; a divide error leaves AX = 0
    if den == 0 then return 0 end
    local q = num / den
    q = q < 0 and math.ceil(q) or math.floor(q)
    if q > 32767 or q < -32768 then return 0 end
    return band(q, M16)
end
local SEED, ARRAY, SPHEREWRAP, SIGNEXTEND, XYANCHOR, GLOBALSEED = 0x4AB0, 0x4CF1, 0x4CCA, 0x4CD8, 0xE356, 0x5979
local SCELL, OCELL = 0xE378, 0xE37C
local DX1, DY1 = 0xE36C, 0xE368

local function rrnd(low, high)            -- [RRND] 0xE3C0 ( low high -- value )
    local seed = rd16(SEED)
    seed = band(s16(seed) * 0x7ABD + 0x1B0F, M16)
    wr16(SEED, seed)
    local range = band(high - low, M16)
    return band(math.floor(seed * range / 65536) + low, M16)
end

local function climit(a, b)               -- C+LIMIT
    local v = s16(band(a + b, M16))
    if v > 0x7F then v = 0x7F end
    if v < -127 then v = -127 end
    return band(v, M16)
end

local function displacement(x, y, std)    -- DISPLACEMENT 0xE3FA ( x y -- r )
    local cx, ax = x, y
    if s16(rd16(XYANCHOR)) > 0 then
        cx = band(cx + rd16(0xE370), M16)
        ax = band(ax + rd16(0xE374), M16)
        if s16(ax) < 0 then
            ax = band(-(ax + 1), M16)
            cx = band(cx + 0x480, M16)
        else
            local dx = 0x3C0
            if not (s16(ax) - dx < 0) then
                ax = band(-(ax - dx) + dx + 1, M16)
                cx = band(cx + 0x480, M16)
            end
        end
        wr16(SEED, ax)
        local v1 = rrnd(1, 0xFFFF)
        wr16(SEED, cx)
        local v2 = rrnd(1, 0xFFFF)
        local seed = bxor(bxor(v2, rd16(GLOBALSEED)), v1)
        wr16(SEED, seed)
    end
    return rrnd(band(-std, M16), std)
end

local function swrap(x, y)                -- [SWRAP] 0xE469
    local arr = rd16(ARRAY)
    local width, height = rd16(arr), rd16(arr + 2)
    if s16(y) < 0 then
        y = band(-(y + 1), M16)
        x = band(x + rshift(width, 1), M16)
    else
        if not (s16(y) - s16(height) < 0) then
            y = band(-(y - height) + height + 1, M16)
            x = band(x + rshift(width, 1), M16)
        end
    end
    if s16(x) < 0 then x = band(x + width, M16)
    elseif not (s16(x) - s16(width) < 0) then x = band(x - width, M16) end
    return x, y
end

local function acelladdr(x, y)            -- [ACELLADDR] 0xE4B9: sets SCELL/OCELL
    if s16(rd16(SPHEREWRAP)) > 0 then x, y = swrap(x, y) end
    local arr = rd16(ARRAY)
    local seg, base = rd16(arr + 6), rd16(arr + 4)
    local off = band(lrd16(seg, band(base + y * 2, M16)) + x, M16)
    wr16(SCELL, seg); wr16(OCELL, off)
end
local function aget()                     -- [A@] 0xE4EF
    local al = lrd8(rd16(SCELL), rd16(OCELL))
    if s16(rd16(SIGNEXTEND)) > 0 then return band(vm.s8(al), M16) end
    return al
end
local function storeheight(h, x, y)       -- [!HEIGHT] 0xE50F
    acelladdr(x, y)
    if aget() == 0xFF80 then
        vm.lwr8(rd16(SCELL), rd16(OCELL), band(h, 0xFF))
    end
end
def("FRACT", 0xE537, function() local y, x, h = pop(), pop(), pop(); storeheight(h, x, y) end)   -- !HEIGHT

local TY = 0xE396
-- the frame f holds the seven FRACTALIZE parameters at their [bp+n] offsets
local function xshift(f, ty)
    acelladdr(f[8], ty); local a = aget()
    acelladdr(f[4], ty); local c = aget()
    local avg = band(arshift(s16(band(a + c, M16)), 1), M16)
    local xm = band(arshift(s16(band(f[8] + f[4], M16)), 1), M16)
    local d = displacement(xm, ty, f[0xE])
    storeheight(climit(avg, d), f[0xC], ty)
end
local function yshift(f, ty)
    acelladdr(ty, f[6]); local a = aget()
    acelladdr(ty, f[2]); local c = aget()
    local avg = band(arshift(s16(band(a + c, M16)), 1), M16)
    local ym = band(arshift(s16(band(f[6] + f[2], M16)), 1), M16)
    local d = displacement(ty, ym, f[0xE])
    storeheight(climit(avg, d), ty, f[0xA])
end

local function fractal(f)
    local ax = s16(f[4]) - s16(f[8]) - 1
    local dx1 = ax > 0 and 1 or 0
    wr16(DX1, dx1)
    local cx = s16(f[2]) - s16(f[6]) - 1
    local dy1 = cx > 0 and 1 or 0
    wr16(DY1, dy1)
    if (dx1 == 0 and dy1 == 0) then return end
    -- MIDPT
    f[0xC] = band(arshift(s16(band(f[8] + f[4], M16)), 1), M16)
    f[0xA] = band(arshift(s16(band(f[6] + f[2], M16)), 1), M16)
    -- EDGES
    if rd16(DY1) > 0 then
        if f[8] == 0 then yshift(f, 0) end
        yshift(f, f[4])
    end
    if rd16(DX1) > 0 then
        if f[6] == 0 then xshift(f, 0) end
        xshift(f, f[2])
    end
    -- CENTER
    if s16(band(rd16(DY1) * rd16(DX1), M16)) > 0 then
        acelladdr(f[0xC], f[6]); local a = aget()
        acelladdr(f[0xC], f[2]); local b = aget()
        acelladdr(f[8], f[0xA]); local c = aget()
        acelladdr(f[4], f[0xA]); local d = aget()
        local avg = band(arshift(s16(band(a + b + c + d, M16)), 2), M16)
        local disp = displacement(f[0xC], f[0xA], f[0xE])
        storeheight(climit(avg, disp), f[0xC], f[0xA])
    end
    -- NEWSTD
    local q = 0
    local r1 = rd16(0xE35E)
    if r1 ~= 0 then
        q = math.floor(f[0xE] * rd16(0xE360) / r1)
        if q > M16 then q = 0 end
    end
    if s16(q) <= 0 then q = 1 end
    f[0xE] = q
    local function child(xl, yl, xu, yu)
        fractal({[0xE] = f[0xE], [0xC] = 0, [0xA] = 0, [8] = xl, [6] = yl, [4] = xu, [2] = yu})
    end
    child(f[8], f[6], f[0xC], f[0xA])
    child(f[0xC], f[6], f[4], f[0xA])
    child(f[8], f[0xA], f[0xC], f[2])
    child(f[0xC], f[0xA], f[4], f[2])
end

def("FRACT", 0xE75E, function()                          -- FRACTALIZE ( std 0 0 xll yll xur yur -- )
    local yur, xur, yll, xll = pop(), pop(), pop(), pop()
    local _, _, std = pop(), pop(), pop()
    fractal({[2] = yur, [4] = xur, [6] = yll, [8] = xll, [0xA] = 0, [0xC] = 0, [0xE] = std})
end)
def("FRACT", 0xE770, function()                          -- FILLARRAY ( byte -- )
    local v = band(pop(), 0xFF)
    local arr = rd16(ARRAY)
    local n, seg = rd16(arr + 4), rd16(arr + 6)
    for i = 0, n - 1 do vm.lwr8(seg, i, v) end
end)
-- stack-frame helpers
local FRAME, TMPV = 0xEACD, 0xED30
def("FRACT", 0xEAD1, function() wr16(FRAME, vm.getsp()) end)                                   -- +FRAME
def("FRACT", 0xEADC, function() vm.setsp(vm.getsp() + 0xE); wr16(FRAME, vm.getsp()) end)         -- -FRAME
def("FRACT", 0xEAEA, function() push(rd16(band(pop() + rd16(FRAME), M16))) end)                  -- @FRAME
def("FRACT", 0xEAF8, function() local a = band(pop() + rd16(FRAME), M16); wr16(a, pop()) end)    -- !FRAME
def("FRACT", 0xED34, function()                                                                  -- +TMP
    wr16(TMPV, vm.getsp())
    local n = pop()
    vm.setsp(vm.getsp() - n * 2)
end)
def("FRACT", 0xED44, function() local n = pop(); vm.setsp(vm.getsp() + n * 2) end)                            -- -TMP
def("FRACT", 0xED50, function() push(rd16(band(rd16(TMPV) - pop() * 2, M16))) end)               -- @TMP
def("FRACT", 0xED62, function() local a = band(rd16(TMPV) - pop() * 2, M16); wr16(a, pop()) end)  -- !TMP
def("FRACT", 0xEE65, function()                                                                  -- PUSH-POLY ( addr -- b w1 w2 )
    local seg = (band(rd16(0x5DA3), 1) == 0) and rd16(0x55D8) or rd16(0x52B3)
    local bx = pop()
    local al = lrd8(seg, bx)
    push(lrd16(seg, bx + 1)); push(lrd16(seg, bx + 3)); push(al)
end)
def("FRACT", 0xEE96, function()                                                                  -- POP-POLY
    local seg = rd16(0x5144)
    local bx = rd16(0xED7D)
    vm.lwr8(seg, bx, pop())
    vm.lwr16(seg, bx + 3, pop())
    vm.lwr16(seg, bx + 1, pop())
    wr16(0xED7D, band(bx + 5, M16))
end)
def("FRACT", 0xEEC2, function() vm.setsp(vm.getsp() + 6) end)                                    -- DROP-POLY
def("FRACT", 0xEECC, function()                                                                  -- ?MCLR
    local v = rd16(vm.getsp())
    push(v == rd16(0xED81) and 1 or 0)
end)
def("FRACT", 0xEEE5, function()                                                                  -- MAINPOLY
    push(0); push(0x0404); push(rd16(0xED81))
end)

-- ---------------------------------------------------------------------------
-- ORBIT-OV: 3-D point work
-- ---------------------------------------------------------------------------
local function interp(k, cx, dx)             -- the table-driven routines at 0xDCE4..0xDD11
    if k == 0 then return cx
    elseif k == 1 then
        local a = arshift(s16(band(dx + cx + 1, M16)), 1)
        return band(arshift(s16(band(a + cx + 1, M16)), 1), M16)
    elseif k == 2 then return band(arshift(s16(band(dx + cx + 1, M16)), 1), M16)
    elseif k == 3 then
        local a = arshift(s16(band(dx + cx + 1, M16)), 1)
        return band(arshift(s16(band(a + dx + 1, M16)), 1), M16)
    else return dx end
end
def("ORBIT", 0xDD2C, function()                                                                  -- WDD2C
    wr16(0xDC24, pop()); wr16(0xDC28, pop())
    local q = rd16(0xDC20)
    local a = interp(rd16(0xDC28), rd16(q + 0xE), rd16(q + 0xA)); push(a)
    local b = interp(rd16(0xDC28), rd16(q + 2), rd16(q + 6))
    push(interp(rd16(0xDC24), pop(), b))
    local c = interp(rd16(0xDC24), rd16(q + 0xC), rd16(q)); push(c)
    local d = interp(rd16(0xDC24), rd16(q + 8), rd16(q + 4))
    push(interp(rd16(0xDC28), pop(), d))
end)
def("ORBIT", 0xDF02, function() wr16(0xDC20, vm.getsp()) end)                                    -- SETQUAD
def("ORBIT", 0xDF13, function()                                                                  -- C*/
    local dl, cl, al = band(pop(), 0xFF), band(pop(), 0xFF), band(pop(), 0xFF)
    local p = vm.s8(al) * vm.s8(cl)
    local q = 0
    if dl ~= 0 then
        q = p / vm.s8(dl); q = q < 0 and math.ceil(q) or math.floor(q)
        if q > 127 or q < -128 then q = 0 end
    end
    push(band(q, M16))
end)
def("ORBIT", 0xE16B, function()                                                                  -- WE16B: translate vertices
    local seg = rd16(0x5DD3)
    local si, di, cx = rd16(0x569B), rd16(0x5DDE), rd16(0x5686)
    local dl, dh, bl = rd8(0xDBD4), rd8(0xDBD8), rd8(0xDBDC)
    for _ = 1, cx do
        lwr8(seg, di, lrd8(seg, si) - dl); lwr8(seg, di + 1, lrd8(seg, si + 1) - dh); lwr8(seg, di + 2, lrd8(seg, si + 2) - bl)
        si = si + 3; di = di + 3
    end
end)
def("ORBIT", 0xE1B6, function()                                                                  -- WE1B6: rotate vertices
    local si = 0xDCC2
    local seg = rd16(0x5DD3)
    for k = 3, 1, -1 do
        local dh, dl, bh = vm.s8(rd8(si)), vm.s8(rd8(si + 2)), vm.s8(rd8(si + 4))
        local base = rd16(si + 6)
        wr16(0xDC0C, base)
        si = si + 8
        local di = band(rd16(0x56A6) + (3 - k) * 2, M16)
        local s2 = rd16(0x5DDE)
        local bp
        for _ = 1, rd16(0x5686) do
            bp = base
            bp = band(bp + vm.s8(lrd8(seg, s2)) * dh, M16)
            bp = band(bp + vm.s8(lrd8(seg, s2 + 1)) * dl, M16)
            bp = band(bp + vm.s8(lrd8(seg, s2 + 2)) * bh, M16)
            s2 = s2 + 3
            lwr16(seg, di, bp)
            di = di + 6
        end
    end
end)
def("ORBIT", 0xE228, function()                                                                  -- WE228: perspective
    local seg = rd16(0x5DD3)
    local di = band(rd16(0x56A6) + 4, M16)
    local si, bp = rd16(0x5DEC), rd16(0xDC14)
    for _ = 1, rd16(0x5686) do
        local bx = s16(lrd16(seg, di)); di = di - 2
        local ax = idiv16(s16(lrd16(seg, di)) * s16(bp), bx)
        lwr16(seg, di, band(ax + si, M16)); di = di - 2
        ax = idiv16(s16(lrd16(seg, di)) * s16(rd16(0xDC10)), bx)
        lwr16(seg, di, band(ax + rd16(0x5DFA), M16))
        di = di + 0xA
    end
end)
def("ORBIT", 0xE48C, function()                                                                  -- WE48C
    local bx = 0xDC38 + 0xE
    for _ = 1, 4 do
        local ax, dx = pop(), pop()
        wr16(bx, dx); bx = bx - 2
        wr16(bx, ax); bx = bx - 2
    end
end)
def("ORBIT", 0xE4AA, function() vm.setsp(vm.getsp() + 0x10) end)                                 -- WE4AA

-- ---------------------------------------------------------------------------
-- MOVE-OV / MAPS-OV  CBLTP ( x y -- ): set up a 4x6 bitmap blit
-- ---------------------------------------------------------------------------
local function cbltp(abltaddr)
    return function()
        wr16(YBLT, band(pop() + 3, M16))
        wr16(XBLT, band(pop() + 6, M16))
        wr16(WBLT, 4); wr16(0x5887, 6); wr16(0x589D, abltaddr)
        wr16(0x58AA, vm.CS)
    end
end
def("MOVE", 0xE8F3, cbltp(0xE8E5))
def("MAPS", 0xEFD9, cbltp(0xEFCB))

-- ---------------------------------------------------------------------------
-- GAME-OV: parameter/return-stack save and restore (non-local exits)
-- ---------------------------------------------------------------------------
local function copymem(dst, src, n) for i = 0, n - 1 do wr8(dst + i, rd8(src + i)) end end
def("GAME", 0xEB4A, function()                                                                   -- PRMSAV
    local bx = pop()
    wr16(bx, vm.getsp())
    copymem(bx + 2, band(rd16(0x78C) - 0x3E8, M16), 0x3E8)
end)
def("GAME", 0xEB72, function()                                                                   -- PRMLOD
    local bx = pop()
    vm.setsp(rd16(bx))
    copymem(band(rd16(0x78C) - 0x3E8, M16), bx + 2, 0x3E8)
    vm.setsp(vm.getsp() + rd16(0xDE72))
end)
def("GAME", 0xEBAA, function()                                                                   -- RETSAV
    local bx = pop()
    wr16(bx, vm.getbp())
    copymem(bx + 2, band(rd16(0x78E) - 0xDC, M16), 0xDC)
end)
def("GAME", 0xEBD2, function()                                                                   -- RETJMP
    local bx = pop()
    local bp = rd16(bx)
    copymem(band(rd16(0x78E) - 0xDC, M16), bx + 2, 0xDC)
    bp = band(bp + rd16(0xDE6E), M16)
    vm.setsi(rd16(bp))
    vm.setbp(bp + 2)
end)

return G

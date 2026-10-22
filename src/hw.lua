-- Text-mode screen, keyboard, ports and sound primitives of STARFLT.COM.
local bit = require("bit")
local band, bor, rshift, lshift = bit.band, bit.bor, bit.rshift, bit.lshift
local vm = require("vm")

local rd8, wr8, rd16, wr16 = vm.rd8, vm.wr8, vm.rd16, vm.wr16
local push, pop, def = vm.push, vm.pop, vm.def
local lrd16, lwr16 = vm.lrd16, vm.lwr16

local IO = {}

-- ---------------------------------------------------------------------------
-- keyboard: a queue of 16-bit key codes as returned by INT 16h:
--   ascii in the low byte, or (scan code, flagged) when ascii is 0
-- ---------------------------------------------------------------------------
IO.keys = {}
function IO.pushkey(code) IO.keys[#IO.keys + 1] = code end

IO.polls = 0
def(0x25BC, function()                                   -- (?TERMINAL)
    if #IO.keys == 0 then IO.polls = IO.polls + 1 end
    push(#IO.keys > 0 and 1 or 0)
end)
def(0x25D7, function()                                   -- (KEY)
    if #IO.keys == 0 then
        vm.setsi(vm.getsi() - 2)                         -- retry this word next time
        vm.yield = true
        return
    end
    local k = table.remove(IO.keys, 1)
    -- Only the EGA graphics path is ported: at the "SELECT DISPLAY MODE" menu, 1-4 mean 5.
    if k >= 0x31 and k <= 0x34 and require("video").mode == "text" then
        local m, b = vm.mem, 0xB8000 + (19 * 80 + 22) * 2
        if m[b] == 83 and m[b + 4] == 69 and m[b + 8] == 76 then k = 0x35 end
    end
    local ascii, scan = band(k, 0xFF), rshift(k, 8)
    if ascii == 0 then push(0x100 + scan) else push(ascii) end
end)

-- ---------------------------------------------------------------------------
-- text screen: segment [di+0x18], cursor in [di+0x1A] (row) / [di+0x1B] (col)
-- ---------------------------------------------------------------------------
local di = function() return vm.getdi() end
IO.cursor = {row = 0, col = 0}

def(0x2767, function()                                   -- (POSITION)
    local d = di()
    local col = band(pop(), 0xFF)
    wr8(d + 0x1B, col)
    local row = band(pop(), 0xFF)
    wr8(d + 0x1A, row)
    IO.cursor.row, IO.cursor.col = row, col
end)
def(0x2836, function()                                   -- ?POSITION
    local d = di()
    push(rd8(d + 0x1A)); push(rd8(d + 0x1B))
end)
def(0x2852, function()                                   -- CUR>ADDR
    local d = di()
    local bx = rd16(d + 0x1A)
    local bl, bh = band(bx, 0xFF), rshift(bx, 8)
    local al = band(rd8(d + 0x1C) + bl, 0xFF)
    local ax = al * 0x50
    bl = band(bh + rd8(d + 0x1D), 0xFF)
    push(band((ax + bl) * 2, 0xFFFF))
end)
def(0x27F8, function()                                   -- >VMOVE ( src dst count -- )
    local d = di()
    local seg = rd16(d + 0x18)
    local attr = band(rshift(rd16(d + 0x20), 8), 0xFF)
    local n, dst, src = pop(), pop(), pop()
    for i = 0, n - 1 do
        lwr16(seg, dst + 2 * i, attr * 256 + rd8(src + i))
    end
end)
def(0x29E1, function()                                   -- V@
    local d = di()
    local off = pop()
    push(band(lrd16(rd16(d + 0x18), off), 0xFF))
end)
def(0x29FC, function()                                   -- V!
    local d = di()
    local off, v = pop(), pop()
    lwr16(rd16(d + 0x18), off, v)
end)
def(0x2A18, function()                                   -- VFILL ( dst count word -- )
    local d = di()
    local seg = rd16(d + 0x18)
    local v, n, dst = pop(), pop(), pop()
    for i = 0, n - 1 do lwr16(seg, dst + 2 * i, v) end
end)
def(0x2A36, function()                                   -- VMOVE ( src dst count -- )
    local d = di()
    local seg = rd16(d + 0x18)
    local n, dst, src = pop(), pop(), pop()
    for i = 0, n - 1 do lwr16(seg, dst + 2 * i, lrd16(seg, src + 2 * i)) end
end)
-- VMOVE- is broken in the original (it jumps through the code address instead of the
-- code field) and the game never calls it; this is what it was meant to do.
def(0x2A5F, function()
    local d = di()
    local seg = rd16(d + 0x18)
    local n, dst, src = pop(), pop(), pop()
    for i = 0, n - 1 do lwr16(seg, dst - 2 * i, lrd16(seg, src - 2 * i)) end
end)
def(0x2973, function()                                   -- SCROLLUP (INT 10h, AH=6)
    local d = di()
    local lines = band(pop(), 0xFF)
    if IO.scroll then
        IO.scroll(lines, 0, 0, rd8(d + 0x1E), rd8(d + 0x1F), rshift(rd16(d + 0x20), 8))
    end
end)

-- ---------------------------------------------------------------------------
-- ports (only a few are meaningful here; the EGA registers are modelled
-- inside the video module)
-- ---------------------------------------------------------------------------
IO.out_hooks = {}
IO.in_hooks = {}
def(0x0D56, function()                                   -- P!
    local port, v = pop(), pop()
    local h = IO.out_hooks[port]
    if h then h(band(v, 0xFF)) end
end)
def(0x0D65, function()                                   -- P@
    local port = pop()
    local h = IO.in_hooks[port]
    push(h and h() or 0)
end)

-- sound: PC speaker
-- IO.sound is the speaker as the game sees it (music and effects share it); IO.music and IO.fx
-- keep the two sources apart for the front end's synthesizer.
IO.sound = {on = false, freq = 0}
IO.music = {on = false, freq = 0}
IO.fx = {on = false, freq = 0}
def(0x2618, function()                                   -- TONE ( divisor -- )
    local div = pop()
    IO.sound.divisor = div
    IO.sound.freq = div > 0 and 1193182 / div or 0
    IO.fx.freq = IO.sound.freq
end)
def(0x2638, function() IO.sound.on = true; IO.fx.on = true end)           -- BEEPON
def(0x2653, function() IO.sound.on = false; IO.fx.on = false; IO.music.on = false end)   -- BEEPOFF: the speaker is off, whoever drove it

return IO

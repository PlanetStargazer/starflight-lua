-- Starflight primitives that deal with the instance database, record
-- addressing, the "C stack" and the vector stack.  Ported from the machine
-- code of STARFLT.COM (see the disassembly comments).
local bit = require("bit")
local band, bor, rshift, lshift = bit.band, bit.bor, bit.rshift, bit.lshift
local vm = require("vm")

local rd8, wr8, rd16, wr16 = vm.rd8, vm.wr8, vm.rd16, vm.wr16
local push, pop, def, s16 = vm.push, vm.pop, vm.def, vm.s16

-- ?UPDATE ( addr -- addr ) marks the block buffer / instance buffer containing addr dirty
def(0x6D12, function()
    local cx = pop()
    if cx >= 0x8000 then
        local c = s16(cx)
        local bx = rd16(0x54A1)                                  -- 1BUFADR
        local dx = s16(band(bx + 7, 0xFFFF))
        if c > dx then
            dx = s16(band(bx + 7 + 0x401, 0xFFFF))
            if dx > c then
                wr8(bx + 2, 0xFF)
            else
                bx = rd16(0x54A5)                                -- 2BUFADR
                dx = s16(band(bx + 7, 0xFFFF))
                if c > dx then
                    dx = s16(band(bx + 7 + 0x401, 0xFFFF))
                    if dx > c then wr8(bx + 2, 0xFF) end
                end
            end
        end
    else
        if cx >= 0x63EF and cx < 0x64FD then wr8(0x63EE, 0xFF) end
    end
    push(cx)
end)

-- VA>BLK ( vaddr.lo vaddr.hi -- block offset )
def(0x6F49, function()
    local ax, dx = pop(), pop()
    push(band(dx, 0x3FF))
    push(band(rshift(dx, 10) + lshift(ax, 6), 0xFFFF))
end)

-- RECADD ( idx recsize off blk -- off' blk' )
def(0x718D, function()
    local s0, s1, s2, s3 = pop(), pop(), pop(), pop()
    local ax = math.floor((0x400 - s1) / s2)
    if s16(ax) > s16(s3) then
        s1 = s1 + band(s3 * s2, 0xFFFF)
    else
        s3 = band(s3 - ax, 0xFFFF)
        s0 = s0 + 1
        s1 = 0
        local cx = math.floor(0x400 / s2)
        local q = math.floor(s3 / cx)
        local rem = s3 - q * cx
        s0 = s0 + q
        s1 = band(rem * s2, 0xFFFF)
    end
    push(band(s1, 0xFFFF)); push(band(s0, 0xFFFF))
end)

-- DOFFBLK ( idx -- offset block )   ("cmp ax,k ; js" looks at the sign of the 16-bit difference only)
def(0x71DD, function()
    local ax = pop()
    local dirblk = rd16(0x535E)
    local function js(k) return band(ax - k, 0x8000) ~= 0 end
    local bx
    if not js(0x90) then bx = dirblk + 3; ax = ax - 0x90
    elseif not js(0x60) then bx = dirblk + 2; ax = ax - 0x60
    elseif not js(0x30) then bx = dirblk + 1; ax = ax - 0x30
    else bx = dirblk end
    ax = band(ax, 0xFFFF)
    if ax >= 0x8000 then ax = ax - 0x10000 end
    push(band(ax * 0x15, 0xFFFF)); push(band(bx, 0xFFFF))
end)

-- BVSA>OFFBLK
def(0x7295, function()
    local ax = band(pop() - 0x3E80, 0xFFFF)
    push(band(ax, 0x3F) * 16)
    push(rshift(ax, 6))
end)

def(0x7425, function() push(band(rd8(pop() + 1) + 0x63EF, 0xFFFF)) end)          -- IFLDADR
def(0x763A, function() push(rd16(0x558C)) end)                                    -- @[IOFF]

-- the 3-byte "C stack" (context stack)
def(0x753F, function()                                                            -- >C
    local bx = rd16(0x54B0)
    local ax = pop()
    wr8(bx + 2, band(ax, 0xFF))
    wr16(bx, pop())
    wr16(0x54B0, band(rd16(0x54B0) - 3, 0xFFFF))
end)
def(0x755A, function()                                                            -- C>
    local p = band(rd16(0x54B0) + 3, 0xFFFF)
    wr16(0x54B0, p)
    push(rd16(p)); push(rd8(p + 2))
end)
def(0x7577, function()                                                            -- CI
    local bx = rd16(0x54B0)
    push(rd16(bx + 3)); push(rd8(bx + 5))
end)
def(0x75D7, function()                                                            -- CDEPTH
    local v = band(0x6398 - rd16(0x54B0), 0xFFFF)
    local q, r = math.floor(v / 3), v % 3
    push(r * 256 + q)
end)

-- vector stack (overlay call stack)
def(0x7AE7, function()                                                            -- >V
    local bx = rd16(0x54B4)
    wr16(bx, pop())
    wr16(0x54B4, band(rd16(0x54B4) - 2, 0xFFFF))
end)
def(0x7AFE, function()                                                            -- V>
    wr16(0x54B4, band(rd16(0x54B4) + 2, 0xFFFF))
    push(rd16(rd16(0x54B4)))
end)
def(0x7B15, function() push(rd16(band(rd16(0x54B4) + 2, 0xFFFF))) end)           -- VI

-- TIME ( -- addr ): 32-bit millisecond counter at 0x188 (hi) / 0x18A (lo).  The
-- original advances it by 55 on every timer tick (INT 1Ch) and refines it from
-- the 8253 counter; here it simply follows the real clock.
vm.now = os.clock
def(0x2A9A, function()
    local t = math.floor(vm.now() * 1000)
    wr16(0x18A, band(t, 0xFFFF))
    wr16(0x188, band(math.floor(t / 65536), 0xFFFF))
    wr16(0x193, 0)
    push(0x188)
end)

-- (SLIPPER) ( n -- [n] flag )
def(0x4C87, function()
    local ax = pop()
    local peak = rd16(0x4C57)                                                     -- PEAK
    local bx = band(ax - peak + 0x80, 0xFFFF)
    local dx
    if rshift(bx, 8) == 0 then
        local bit_idx = band(bx, 7)
        local curve = rd8(rshift(bx, 3) + 0x4C5B)                                 -- CURVE
        bx = rshift(rd16(0x4C4C), bit_idx)                                        -- FILTER
        dx = band(peak, 0xFF00) + curve
    else
        bx, dx = 0, 0
    end
    bx = band(bx, dx)
    if bx ~= 0 then push(ax) end
    push(bx)
end)

-- W4D5C ( index base-word -- seg offset ): 2-D array element locator
def(0x4D5C, function()
    local bx = pop() + 6
    local ax = rd16(bx)                                                           -- segment
    local cx = rd16(bx - 2)
    local idx = pop() * 2
    local off = band(cx + idx, 0xFFFF)
    local val = vm.lrd16(ax, off)
    local dx = pop()
    push(ax); push(band(val + dx, 0xFFFF))
end)

-- !OFFSETS: fills a table of row offsets  ( paramptr -- )
def(0x4DA4, function()
    local bx = pop()
    local mult = rd16(bx)
    local n = rd16(bx + 2)
    local base = rd16(bx + 4)
    local seg = rd16(bx + 6)
    local di = band(n * 2 + base, 0xFFFF)
    local cx = n
    repeat
        vm.lwr16(seg, di, band(mult * cx, 0xFFFF))
        di = band(di - 2, 0xFFFF)
        cx = cx - 1
    until cx == 0
    vm.lwr16(seg, di, 0)
end)

def(0x4892, function() end)                                                       -- CAPSON

def(0x4873, function() wr16(pop(), 1) end)                                        -- ON
def(0x4886, function() wr16(pop(), 0) end)                                        -- OFF

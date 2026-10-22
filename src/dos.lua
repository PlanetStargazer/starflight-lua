-- DOS / BIOS services used by Starflight through the INTERRUPT word.
--
-- The game talks to DOS through FCBs (CP/M style file control blocks) and
-- only ever touches two data files, STARA.COM and STARB.COM, with random
-- record reads and writes.  Both files are held in memory; writes mark them
-- dirty and `D.flush()` persists them through the supplied `save` callback.

local bit = require("bit")
local band, rshift = bit.band, bit.rshift
local vm = require("vm")

local D = {}
local rd8, wr8, rd16, wr16 = vm.rd8, vm.wr8, vm.rd16, vm.wr16
local mem, DSB = vm.mem, vm.DSB

D.writes = 0
D.files = {}        -- ["A"] = {data = <string or table>, size = n, dirty = bool}
D.video = nil       -- set by main: video.setmode / video.setcursor / video.scroll
D.log = nil

local dta_seg, dta_off = 0, 0

-- file images are kept as uint8 cdata arrays
local ffi = require("ffi")
function D.addfile(letter, str, size)
    local buf = ffi.new("uint8_t[?]", math.max(size or #str, #str))
    ffi.copy(buf, str, #str)
    D.files[letter] = {buf = buf, size = size or #str, dirty = false}
end

function D.flush(save)
    for letter, f in pairs(D.files) do
        if f.dirty and save then
            save(letter, ffi.string(f.buf, f.size))
            f.dirty = false
        end
    end
end

local function filefor(dx)
    return D.files[string.char(rd8(dx + 5))]
end

function D.getstate()
    local t = {dta_seg = dta_seg, dta_off = dta_off, files = {}}
    for letter, f in pairs(D.files) do t.files[letter] = {data = ffi.string(f.buf, f.size), size = f.size, dirty = f.dirty} end
    return t
end
function D.setstate(t)
    dta_seg, dta_off = t.dta_seg, t.dta_off
    for letter, f in pairs(t.files) do
        D.addfile(letter, f.data, f.size)
        D.files[letter].dirty = f.dirty
    end
end

local handlers = {}
D.handlers = handlers

-- INT 10h: video BIOS
handlers[0x10] = function(r)
    local ah = rshift(r.ax, 8)
    if ah == 0x0F then
        local mode = D.video and D.video.getmode() or 3
        r.ax = 0x5000 + mode                                   -- 80 columns, current mode
    elseif ah == 0x00 then
        if D.video then D.video.setmode(band(r.ax, 0xFF)) end
    elseif ah == 0x02 then
        if D.video then D.video.setcursor(rshift(r.dx, 8), band(r.dx, 0xFF)) end
    elseif ah == 0x06 then
        if D.video then D.video.scroll(band(r.ax, 0xFF), rshift(r.cx, 8), band(r.cx, 0xFF),
            rshift(r.dx, 8), band(r.dx, 0xFF), rshift(r.bx, 8)) end
    elseif ah == 0x01 or ah == 0x05 or ah == 0x0B then
        -- cursor shape / active page / palette: nothing to do
    elseif ah == 0x12 then
        -- alternate select: EGA information; report "no EGA BIOS" and let the game probe ports
        -- (leave BL untouched)
    else
        if D.log then D.log(string.format("INT 10h AH=%02X unhandled", ah)) end
    end
end

-- INT 11h: equipment list
handlers[0x11] = function(r) r.ax = 0xD426 end

-- INT 21h: DOS
handlers[0x21] = function(r)
    local ah = rshift(r.ax, 8)
    if ah == 0x0D then
        -- disk reset
    elseif ah == 0x0F then                       -- open file (FCB)
        r.ax = band(r.ax, 0xFF00)
        wr8(r.dx, 3)
    elseif ah == 0x10 then                       -- close file
        r.ax = band(r.ax, 0xFF00)
        if D.onclose then D.onclose() end
    elseif ah == 0x1A then                       -- set DTA
        dta_seg, dta_off = r.ds, r.dx
    elseif ah == 0x19 then                       -- get default drive
        r.ax = band(r.ax, 0xFF00) + 2
    elseif ah == 0x22 or ah == 0x21 then         -- random write / read
        local size = rd16(r.dx + 0x0E)
        local block = rd16(r.dx + 0x21) + rd8(r.dx + 0x23) * 65536
        local f = filefor(r.dx)
        local base = block * size
        local dst = band(dta_seg * 16 + dta_off, 0xFFFFF)
        r.ax = band(r.ax, 0xFF00)
        if not f or base + size > f.size then
            r.ax = band(r.ax, 0xFF00) + 1        -- end of file / no data
        elseif ah == 0x22 then
            ffi.copy(f.buf + base, mem + dst, size)
            f.dirty = true
            D.writes = D.writes + 1
        else
            ffi.copy(mem + dst, f.buf + base, size)
        end
    elseif ah == 0x11 then                       -- find first file
        r.ax = band(r.ax, 0xFF00)
    elseif ah == 0x4A then                       -- resize memory block
        r.ax = 0x1FE
    elseif ah == 0x29 then                       -- parse filename into FCB
        local s = r.si_in or 0
        for i = 0, 4 do wr8(r.di + i + 1, rd8(s + i)) end    -- STARA / STARB
        wr8(r.di, 0)
        local isb = rd8(s + 4) == string.byte("B")
        local len = isb and 362496 or 256000
        for i = 0, 3 do wr8(r.di + 0x10 + i, band(rshift(len, 8 * i), 0xFF)) end
        r.ax = band(r.ax, 0xFF00)
        r.bx = 0
    elseif ah == 0x2C then                       -- get time
        local t = os.date("*t")
        r.cx = t.hour * 256 + t.min
        r.dx = t.sec * 256
    elseif ah == 0x2A then                       -- get date
        local t = os.date("*t")
        r.cx = t.year
        r.dx = t.month * 256 + t.day
    elseif ah == 0x30 then
        r.ax = 0x0003                            -- DOS 3.0
    else
        error(string.format("unsupported DOS call AH=%02X", ah))
    end
end

handlers[0x16] = function(r) end                 -- keyboard BIOS: handled by dedicated words

-- the INTERRUPT word: ( int# -- ), register image at 0x16B4
vm.def(0x16D9, function()
    local int = vm.pop()
    local r = {
        flags = rd16(0x16B4), ax = rd16(0x16B6), bx = rd16(0x16B8), cx = rd16(0x16BA),
        dx = rd16(0x16BC), di = rd16(0x16C0), si_in = rd16(0x16C2), ds = rd16(0x16C4),
        es = rd16(0x16C6),
    }
    wr8(0x16C9, int)
    local h = handlers[int]
    if not h then error(string.format("unsupported interrupt %02Xh", int)) end
    h(r)
    wr16(0x16B4, bit.bor(r.flags, 0xF000)); wr16(0x16B6, band(r.ax, 0xFFFF)); wr16(0x16B8, band(r.bx, 0xFFFF))
    wr16(0x16BA, band(r.cx, 0xFFFF)); wr16(0x16BC, band(r.dx, 0xFFFF))
    wr16(0x16C0, band(r.di, 0xFFFF)); wr16(0x16C4, r.ds); wr16(0x16C6, r.es)
end)

-- interrupt vector table access ((!OLD) reads, (!SET) writes), segment 0
vm.def(0x0160, function()
    local n = vm.pop()
    local a = n * 4
    vm.push(mem[a + 2] + mem[a + 3] * 256)
    vm.push(mem[a] + mem[a + 1] * 256)
end)
vm.def(0x0138, function()
    local n, off, seg = vm.pop(), vm.pop(), vm.pop()
    local a = n * 4
    mem[a] = band(off, 0xFF); mem[a + 1] = rshift(off, 8)
    mem[a + 2] = band(seg, 0xFF); mem[a + 3] = rshift(seg, 8)
end)
-- SET0/: installs the divide-error handler.  After its self-test the vector points at
-- CS:01C7 ("sub ax,ax / sub dx,dx / iret"), i.e. a division by zero yields 0.
vm.def(0x01FA, function()
    mem[0], mem[1], mem[2], mem[3] = 0xC7, 0x01, vm.CS % 256, math.floor(vm.CS / 256)
end)
vm.def(0x4A0C, function() end)                   -- PRTSCR

return D

-- EGA graphics adapter model (planar memory, write modes 0-3, latches).
-- Starflight runs the adapter in BIOS mode 0Dh (320x200, 16 colours,
-- 8000 bytes per plane and page).  Segment A000 is routed here by vm.lua.

local ffi = require("ffi")
local bit = require("bit")
local band, bor, bxor, bnot, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.bnot, bit.lshift, bit.rshift

local E = {}

local PLANE = 0x10000
local mem = ffi.new("uint8_t[?]", PLANE * 4)       -- plane p at p*PLANE
E.mem = mem

local latch = {[0] = 0, 0, 0, 0}
local map_mask = 0x0F                              -- sequencer reg 2
local seq_index, gc_index, crtc_index = 0, 0, 0
local gc = {[0] = 0, 0, 0, 0, 0, 0, 0, 0x0F, 0xFF} -- set/reset, enable s/r, colour compare,
                                                   -- rotate/function, read map, mode, misc, don't care, bit mask
local crtc = {}
E.gc, E.crtc = gc, crtc
E.active = false                                   -- true once a graphics mode has been set

-- ---------------------------------------------------------------------------
-- port interface
-- ---------------------------------------------------------------------------
function E.out(port, v)
    v = band(v, 0xFF)
    if port == 0x3C4 then seq_index = v
    elseif port == 0x3C5 then
        if seq_index == 2 then map_mask = band(v, 0x0F) end
    elseif port == 0x3CE then gc_index = v
    elseif port == 0x3CF then gc[gc_index] = v
    elseif port == 0x3D4 or port == 0x3B4 then crtc_index = v
    elseif port == 0x3D5 or port == 0x3B5 then crtc[crtc_index] = v
    end
end
function E.inp(port)
    if port == 0x3DA or port == 0x3BA then
        E.retrace = (E.retrace or 0) + 1
        return band(E.retrace, 4) == 0 and 9 or 0        -- toggles the retrace bits so that wait loops end
    elseif port == 0x3CF then return gc[gc_index] or 0
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- memory interface (offset inside the A000 segment)
-- ---------------------------------------------------------------------------
local function ror8(v, n)
    n = band(n, 7)
    if n == 0 then return v end
    return band(bor(rshift(v, n), lshift(v, 8 - n)), 0xFF)
end

local function logic(func, d, l)
    if func == 0 then return d
    elseif func == 1 then return band(d, l)
    elseif func == 2 then return bor(d, l)
    else return bxor(d, l) end
end

function E.write(off, v)
    if off >= PLANE then return end
    local wmode = band(gc[5], 3)
    local bm, rot, func = gc[8], band(gc[3], 7), band(rshift(gc[3], 3), 3)
    if wmode == 1 then
        for p = 0, 3 do
            if band(map_mask, lshift(1, p)) ~= 0 then mem[p * PLANE + off] = latch[p] end
        end
        return
    end
    if wmode == 0 then
        v = ror8(v, rot)
    elseif wmode == 3 then
        v = ror8(v, rot)
        bm = band(bm, v)
    end
    local sr, esr = gc[0], gc[1]
    for p = 0, 3 do
        if band(map_mask, lshift(1, p)) ~= 0 then
            local bitp = lshift(1, p)
            local d
            if wmode == 0 then
                if band(esr, bitp) ~= 0 then d = band(sr, bitp) ~= 0 and 0xFF or 0 else d = v end
            elseif wmode == 2 then
                d = band(v, bitp) ~= 0 and 0xFF or 0
            else
                d = band(sr, bitp) ~= 0 and 0xFF or 0
            end
            local l = latch[p]
            d = logic(func, d, l)
            mem[p * PLANE + off] = bor(band(d, bm), band(l, bnot(bm)))
        end
    end
end

function E.read(off)
    if off >= PLANE then return 0xFF end
    for p = 0, 3 do latch[p] = mem[p * PLANE + off] end
    if band(gc[5], 8) == 0 then
        return latch[band(gc[4], 3)]
    end
    -- read mode 1: colour compare
    local cc, dc = gc[2], gc[7]
    local r = 0xFF
    for p = 0, 3 do
        if band(dc, lshift(1, p)) ~= 0 then
            local want = band(cc, lshift(1, p)) ~= 0 and 0xFF or 0
            r = band(r, bnot(bxor(latch[p], want)))
        end
    end
    return band(r, 0xFF)
end

-- state snapshot (development tools)
function E.getstate()
    local t = {gc = {}, crtc = {}, latch = {}, map_mask = map_mask, seq_index = seq_index, gc_index = gc_index,
        crtc_index = crtc_index, active = E.active, planes = ffi.string(mem, PLANE * 4), retrace = E.retrace}
    for i = 0, 8 do t.gc[i] = gc[i] end
    for k, v in pairs(crtc) do t.crtc[k] = v end
    for i = 0, 3 do t.latch[i] = latch[i] end
    return t
end
function E.setstate(t)
    for i = 0, 8 do gc[i] = t.gc[i] end
    for k in pairs(crtc) do crtc[k] = nil end
    for k, v in pairs(t.crtc) do crtc[k] = v end
    for i = 0, 3 do latch[i] = t.latch[i] end
    map_mask, seq_index, gc_index, crtc_index = t.map_mask, t.seq_index, t.gc_index, t.crtc_index
    E.active, E.retrace = t.active, t.retrace
    ffi.copy(mem, t.planes, PLANE * 4)
end

-- ---------------------------------------------------------------------------
-- mode switch and display conversion
-- ---------------------------------------------------------------------------
function E.setmode(clear)
    gc[0], gc[1], gc[2], gc[3], gc[4], gc[5], gc[7], gc[8] = 0, 0, 0, 0, 0, 0, 0x0F, 0xFF
    map_mask = 0x0F
    if clear then ffi.fill(mem, PLANE * 4, 0) end
    E.active = true
end

-- default EGA palette (16 colours) as 0xRRGGBB
local function rgb(r, g, b) return {r / 255, g / 255, b / 255} end
E.palette = {}
do
    local base = {
        {0, 0, 0}, {0, 0, 170}, {0, 170, 0}, {0, 170, 170},
        {170, 0, 0}, {170, 0, 170}, {170, 85, 0}, {170, 170, 170},
        {85, 85, 85}, {85, 85, 255}, {85, 255, 85}, {85, 255, 255},
        {255, 85, 85}, {255, 85, 255}, {255, 255, 85}, {255, 255, 255},
    }
    for i = 0, 15 do E.palette[i] = base[i + 1] end
end

-- render the 320x200 visible page into an RGBA buffer (w*h*4 bytes)
function E.render(buf, stride)
    local start = (crtc[0x0C] or 0) * 256 + (crtc[0x0D] or 0)
    local pal = E.palette
    stride = stride or 320
    for y = 0, 199 do
        local idx = y * stride * 4
        for xb = 0, 39 do
            local o = band(start + y * 40 + xb, 0xFFFF)
            local b0, b1, b2, b3 = mem[o], mem[PLANE + o], mem[2 * PLANE + o], mem[3 * PLANE + o]
            for bitn = 7, 0, -1 do
                local c = band(rshift(b0, bitn), 1) + 2 * band(rshift(b1, bitn), 1)
                          + 4 * band(rshift(b2, bitn), 1) + 8 * band(rshift(b3, bitn), 1)
                local col = pal[c]
                buf[idx] = col[1]; buf[idx + 1] = col[2]; buf[idx + 2] = col[3]; buf[idx + 3] = 255
                idx = idx + 4
            end
        end
    end
end

return E

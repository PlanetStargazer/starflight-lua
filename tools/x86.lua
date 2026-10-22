-- Minimal 8086 interpreter.  DEVELOPMENT TOOL ONLY: it executes the original
-- STARFLT.COM machine code so that the Lua port in src/ can be compared
-- against the real thing, one Forth word at a time.  It is not used by the game.

local bit = require("bit")
local band, bor, bxor, bnot, lshift, rshift, arshift = bit.band, bit.bor, bit.bxor, bit.bnot, bit.lshift, bit.rshift, bit.arshift

local X = {}
local R = {[0] = 0, 0, 0, 0, 0, 0, 0, 0}        -- ax cx dx bx sp bp si di
local S = {[0] = 0, 0, 0, 0}                     -- es cs ss ds
local ip = 0
local CF, PF, AF, ZF, SF, OF, DF, IF, TF = 0, 0, 0, 0, 0, 0, 0, 1, 0
X.R, X.S = R, S

local vm = require("vm")
local mem = vm.mem
local lrd8, lwr8 = vm.lrd8, vm.lwr8       -- these route A000 to the EGA model

X.ports_in, X.ports_out = {}, {}
X.int_handler = nil                           -- function(n, X) for software interrupts
X.hle = {}                                    -- code address -> function() replacing machine code (must "ret" itself)
X.dispatch_hook = nil                         -- called at each "jmp [bx]" (Forth NEXT)

local function lin(seg, off) return band(seg * 16 + band(off, 0xFFFF), 0xFFFFF) end

local function rb(seg, off) return lrd8(seg, band(off, 0xFFFF)) end
X.watch = nil
local function wb(seg, off, v)
    if X.watch and band(seg * 16 + band(off, 0xFFFF), 0xFFFFF) == X.watch then X.onwatch(v, seg, off) end
    lwr8(seg, band(off, 0xFFFF), v)
end
local function rw(seg, off) return rb(seg, off) + rb(seg, off + 1) * 256 end
local function ww(seg, off, v) wb(seg, off, v); wb(seg, off + 1, rshift(v, 8)) end
X.rb, X.wb, X.rw, X.ww = rb, wb, rw, ww

local PARITY = {}
for i = 0, 255 do
    local n, v = 0, i
    while v > 0 do n = n + band(v, 1); v = rshift(v, 1) end
    PARITY[i] = (n % 2 == 0) and 1 or 0
end

local function getflags()
    return CF + 2 + PF * 4 + AF * 16 + ZF * 64 + SF * 128 + TF * 256 + IF * 512 + DF * 1024 + OF * 2048 + 0xF000
end
local function setflags(v)
    CF = band(v, 1); PF = band(rshift(v, 2), 1); AF = band(rshift(v, 4), 1); ZF = band(rshift(v, 6), 1)
    SF = band(rshift(v, 7), 1); TF = band(rshift(v, 8), 1); IF = band(rshift(v, 9), 1)
    DF = band(rshift(v, 10), 1); OF = band(rshift(v, 11), 1)
end
X.getflags, X.setflags = getflags, setflags

local function fetch8() local v = rb(S[1], ip); ip = band(ip + 1, 0xFFFF); return v end
local function fetch16() local v = fetch8(); return v + fetch8() * 256 end
local function s8(v) return v >= 0x80 and v - 0x100 or v end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end

local function push(v) R[4] = band(R[4] - 2, 0xFFFF); ww(S[2], R[4], v) end
local function pop() local v = rw(S[2], R[4]); R[4] = band(R[4] + 2, 0xFFFF); return v end

local function r8(i) if i < 4 then return band(R[i], 0xFF) else return rshift(R[i - 4], 8) end end
local function w8(i, v)
    v = band(v, 0xFF)
    if i < 4 then R[i] = bor(band(R[i], 0xFF00), v) else R[i - 4] = bor(band(R[i - 4], 0xFF), lshift(v, 8)) end
end

-- ALU ---------------------------------------------------------------------
local function setszp(res, w)
    local mask = w == 8 and 0xFF or 0xFFFF
    res = band(res, mask)
    ZF = res == 0 and 1 or 0
    SF = band(rshift(res, w - 1), 1)
    PF = PARITY[band(res, 0xFF)]
    return res
end
local function add(a, b, c, w)
    local mask = w == 8 and 0xFF or 0xFFFF
    local r = a + b + c
    CF = r > mask and 1 or 0
    AF = band(bxor(bxor(a, b), r), 0x10) ~= 0 and 1 or 0
    local sign = lshift(1, w - 1)
    OF = (band(a, sign) == band(b, sign) and band(r, sign) ~= band(a, sign)) and 1 or 0
    return setszp(r, w)
end
local function sub(a, b, c, w)
    local mask = w == 8 and 0xFF or 0xFFFF
    local r = a - b - c
    CF = r < 0 and 1 or 0
    AF = band(bxor(bxor(a, b), r), 0x10) ~= 0 and 1 or 0
    local sign = lshift(1, w - 1)
    OF = (band(a, sign) ~= band(b, sign) and band(r, sign) ~= band(a, sign)) and 1 or 0
    return setszp(band(r, mask), w)
end
local function logic(r, w)
    CF = 0; OF = 0; AF = 0
    return setszp(r, w)
end
local function alu(op, a, b, w)
    if op == 0 then return add(a, b, 0, w)
    elseif op == 1 then return logic(bor(a, b), w)
    elseif op == 2 then return add(a, b, CF, w)
    elseif op == 3 then return sub(a, b, CF, w)
    elseif op == 4 then return logic(band(a, b), w)
    elseif op == 5 or op == 7 then return sub(a, b, 0, w)
    else return logic(bxor(a, b), w) end
end

local function shift(op, v, n, w)
    local mask = w == 8 and 0xFF or 0xFFFF
    local sign = lshift(1, w - 1)
    n = band(n, 0xFF)
    if n == 0 then return v end
    if op == 0 then                      -- rol
        for _ = 1, n % w do v = band(bor(lshift(v, 1), rshift(v, w - 1)), mask) end
        CF = band(v, 1)
        OF = bxor(band(rshift(v, w - 1), 1), CF)
    elseif op == 1 then                  -- ror
        for _ = 1, n % w do v = band(bor(rshift(v, 1), lshift(band(v, 1), w - 1)), mask) end
        CF = band(rshift(v, w - 1), 1)
        OF = bxor(band(rshift(v, w - 1), 1), band(rshift(v, w - 2), 1))
    elseif op == 2 then                  -- rcl
        for _ = 1, n do
            local c = band(rshift(v, w - 1), 1)
            v = band(bor(lshift(v, 1), CF), mask); CF = c
        end
        OF = bxor(band(rshift(v, w - 1), 1), CF)
    elseif op == 3 then                  -- rcr
        for _ = 1, n do
            local c = band(v, 1)
            v = band(bor(rshift(v, 1), lshift(CF, w - 1)), mask); CF = c
        end
        OF = bxor(band(rshift(v, w - 1), 1), band(rshift(v, w - 2), 1))
    elseif op == 4 or op == 6 then       -- shl
        for _ = 1, n do
            CF = band(rshift(v, w - 1), 1)
            v = band(lshift(v, 1), mask)
        end
        OF = bxor(band(rshift(v, w - 1), 1), CF)
        v = setszp(v, w)
    elseif op == 5 then                  -- shr
        OF = band(rshift(v, w - 1), 1)
        for _ = 1, n do CF = band(v, 1); v = rshift(v, 1) end
        v = setszp(v, w)
    else                                 -- sar
        OF = 0
        for _ = 1, n do
            CF = band(v, 1)
            v = bor(rshift(v, 1), band(v, sign))
        end
        v = setszp(v, w)
    end
    return v
end

-- effective addresses -----------------------------------------------------
local segover = nil
local m_mod, m_reg, m_rm, m_seg, m_off
local function decode_modrm()
    local b = fetch8()
    m_mod, m_reg, m_rm = rshift(b, 6), band(rshift(b, 3), 7), band(b, 7)
    if m_mod == 3 then return end
    local off, seg = 0, 3
    local rm = m_rm
    if rm == 0 then off = R[3] + R[6]
    elseif rm == 1 then off = R[3] + R[7]
    elseif rm == 2 then off = R[5] + R[6]; seg = 2
    elseif rm == 3 then off = R[5] + R[7]; seg = 2
    elseif rm == 4 then off = R[6]
    elseif rm == 5 then off = R[7]
    elseif rm == 6 then
        if m_mod == 0 then off = fetch16() else off = R[5]; seg = 2 end
    else off = R[3] end
    if m_mod == 1 then off = off + s8(fetch8()) elseif m_mod == 2 then off = off + fetch16() end
    m_off = band(off, 0xFFFF)
    m_seg = segover or S[seg]
end
local function get_rm(w)
    if m_mod == 3 then return w == 8 and r8(m_rm) or R[m_rm] end
    return w == 8 and rb(m_seg, m_off) or rw(m_seg, m_off)
end
local function set_rm(w, v)
    if m_mod == 3 then
        if w == 8 then w8(m_rm, v) else R[m_rm] = band(v, 0xFFFF) end
    else
        if w == 8 then wb(m_seg, m_off, v) else ww(m_seg, m_off, v) end
    end
end
local function get_reg(w) return w == 8 and r8(m_reg) or R[m_reg] end
local function set_reg(w, v) if w == 8 then w8(m_reg, v) else R[m_reg] = band(v, 0xFFFF) end end

local function cond(c)
    local r
    local t = rshift(c, 1)
    if t == 0 then r = OF == 1
    elseif t == 1 then r = CF == 1
    elseif t == 2 then r = ZF == 1
    elseif t == 3 then r = CF == 1 or ZF == 1
    elseif t == 4 then r = SF == 1
    elseif t == 5 then r = PF == 1
    elseif t == 6 then r = SF ~= OF
    else r = ZF == 1 or SF ~= OF end
    if band(c, 1) == 1 then return not r end
    return r
end

local function do_int(n)
    if X.int_handler and X.int_handler(n, X) then return end
    -- through the interrupt vector table
    push(getflags()); push(S[1]); push(ip)
    IF = 0; TF = 0
    ip = rw(0, n * 4); S[1] = rw(0, n * 4 + 2)
end

-- one instruction ---------------------------------------------------------
local steps = 0
function X.step()
    steps = steps + 1
    local startip = ip
    segover = nil
    local rep = nil
    local op = fetch8()
    while true do
        if op == 0x26 then segover = S[0]
        elseif op == 0x2E then segover = S[1]
        elseif op == 0x36 then segover = S[2]
        elseif op == 0x3E then segover = S[3]
        elseif op == 0xF2 or op == 0xF3 then rep = op
        elseif op == 0xF0 then
        else break end
        op = fetch8()
    end
    local hi = rshift(op, 6)
    if op < 0x40 and band(op, 7) < 6 then
        local aop, form = rshift(op, 3), band(op, 7)
        local w = band(form, 1) == 0 and 8 or 16
        if form < 4 then
            decode_modrm()
            local a, b
            if form < 2 then a, b = get_rm(w), get_reg(w) else a, b = get_reg(w), get_rm(w) end
            local r = alu(aop, a, b, w)
            if aop ~= 7 then
                if form < 2 then set_rm(w, r) else set_reg(w, r) end
            end
        else
            local imm = w == 8 and fetch8() or fetch16()
            local a = w == 8 and r8(0) or R[0]
            local r = alu(aop, a, imm, w)
            if aop ~= 7 then if w == 8 then w8(0, r) else R[0] = r end end
        end
    elseif op == 0x06 then push(S[0])
    elseif op == 0x0E then push(S[1])
    elseif op == 0x16 then push(S[2])
    elseif op == 0x1E then push(S[3])
    elseif op == 0x07 then S[0] = pop()
    elseif op == 0x17 then S[2] = pop()
    elseif op == 0x1F then S[3] = pop()
    elseif op == 0x27 or op == 0x2F then                     -- daa / das
        local al, oldcf = r8(0), CF
        if band(al, 0xF) > 9 or AF == 1 then
            al = op == 0x27 and al + 6 or al - 6; AF = 1
        else AF = 0 end
        if r8(0) > 0x99 or oldcf == 1 then al = op == 0x27 and al + 0x60 or al - 0x60; CF = 1 else CF = 0 end
        w8(0, setszp(al, 8))
    elseif op == 0x37 or op == 0x3F then                     -- aaa / aas
        if band(r8(0), 0xF) > 9 or AF == 1 then
            if op == 0x37 then R[0] = band(R[0] + 0x106, 0xFFFF) else R[0] = band(R[0] - 6, 0xFFFF); w8(4, r8(4) - 1) end
            AF = 1; CF = 1
        else AF = 0; CF = 0 end
        w8(0, band(r8(0), 0xF))
    elseif op >= 0x40 and op <= 0x47 then
        local c = CF; R[op - 0x40] = add(R[op - 0x40], 1, 0, 16); CF = c
    elseif op >= 0x48 and op <= 0x4F then
        local c = CF; R[op - 0x48] = sub(R[op - 0x48], 1, 0, 16); CF = c
    elseif op >= 0x50 and op <= 0x57 then
        local r = op - 0x50
        if r == 4 then push(band(R[4] - 2, 0xFFFF)) else push(R[r]) end      -- push sp pushes the new value (8086)
    elseif op >= 0x58 and op <= 0x5F then R[op - 0x58] = pop()
    elseif op >= 0x70 and op <= 0x7F then
        local d = s8(fetch8())
        if cond(op - 0x70) then ip = band(ip + d, 0xFFFF) end
    elseif op >= 0x80 and op <= 0x83 then
        decode_modrm()
        local w = band(op, 1) == 0 and 8 or 16
        local a = get_rm(w)
        local imm
        if op == 0x81 then imm = fetch16()
        elseif op == 0x83 then imm = band(s8(fetch8()), 0xFFFF)
        else imm = fetch8() end
        if w == 8 then imm = band(imm, 0xFF) end
        local r = alu(m_reg, a, imm, w)
        if m_reg ~= 7 then set_rm(w, r) end
    elseif op == 0x84 or op == 0x85 then
        decode_modrm(); local w = op == 0x84 and 8 or 16
        logic(band(get_rm(w), get_reg(w)), w)
    elseif op == 0x86 or op == 0x87 then
        decode_modrm(); local w = op == 0x86 and 8 or 16
        local a, b = get_rm(w), get_reg(w)
        set_rm(w, b); set_reg(w, a)
    elseif op >= 0x88 and op <= 0x8B then
        decode_modrm(); local w = band(op, 1) == 0 and 8 or 16
        if op < 0x8A then set_rm(w, get_reg(w)) else set_reg(w, get_rm(w)) end
    elseif op == 0x8C then decode_modrm(); set_rm(16, S[band(m_reg, 3)])
    elseif op == 0x8D then decode_modrm(); R[m_reg] = m_off
    elseif op == 0x8E then decode_modrm(); S[band(m_reg, 3)] = get_rm(16)
    elseif op == 0x8F then decode_modrm(); set_rm(16, pop())
    elseif op == 0x90 then
    elseif op >= 0x91 and op <= 0x97 then R[0], R[op - 0x90] = R[op - 0x90], R[0]
    elseif op == 0x98 then R[0] = band(s8(r8(0)), 0xFFFF)
    elseif op == 0x99 then R[2] = R[0] >= 0x8000 and 0xFFFF or 0
    elseif op == 0x9A then
        local o, sg = fetch16(), fetch16()
        push(S[1]); push(ip); ip = o; S[1] = sg
    elseif op == 0x9B then
    elseif op == 0x9C then push(getflags())
    elseif op == 0x9D then setflags(pop())
    elseif op == 0x9E then local f = r8(4); CF = band(f, 1); PF = band(rshift(f, 2), 1); AF = band(rshift(f, 4), 1); ZF = band(rshift(f, 6), 1); SF = band(rshift(f, 7), 1)
    elseif op == 0x9F then w8(4, band(getflags(), 0xFF))
    elseif op >= 0xA0 and op <= 0xA3 then
        local off = fetch16()
        local sg = segover or S[3]
        if op == 0xA0 then w8(0, rb(sg, off)) elseif op == 0xA1 then R[0] = rw(sg, off)
        elseif op == 0xA2 then wb(sg, off, r8(0)) else ww(sg, off, R[0]) end
    elseif (op >= 0xA4 and op <= 0xA7) or (op >= 0xAA and op <= 0xAF) then
        local w = band(op, 1) == 0 and 8 or 16
        local step = (w == 8 and 1 or 2) * (DF == 1 and -1 or 1)
        local function once()
            if op == 0xA4 or op == 0xA5 then
                local sg = segover or S[3]
                if w == 8 then wb(S[0], R[7], rb(sg, R[6])) else ww(S[0], R[7], rw(sg, R[6])) end
                R[6] = band(R[6] + step, 0xFFFF); R[7] = band(R[7] + step, 0xFFFF)
            elseif op == 0xA6 or op == 0xA7 then
                local sg = segover or S[3]
                local a = w == 8 and rb(sg, R[6]) or rw(sg, R[6])
                local b = w == 8 and rb(S[0], R[7]) or rw(S[0], R[7])
                sub(a, b, 0, w)
                R[6] = band(R[6] + step, 0xFFFF); R[7] = band(R[7] + step, 0xFFFF)
            elseif op == 0xAA or op == 0xAB then
                if w == 8 then wb(S[0], R[7], r8(0)) else ww(S[0], R[7], R[0]) end
                R[7] = band(R[7] + step, 0xFFFF)
            elseif op == 0xAC or op == 0xAD then
                local sg = segover or S[3]
                if w == 8 then w8(0, rb(sg, R[6])) else R[0] = rw(sg, R[6]) end
                R[6] = band(R[6] + step, 0xFFFF)
            else
                local a = w == 8 and r8(0) or R[0]
                local b = w == 8 and rb(S[0], R[7]) or rw(S[0], R[7])
                sub(a, b, 0, w)
                R[7] = band(R[7] + step, 0xFFFF)
            end
        end
        if rep then
            local cmpop = (op == 0xA6 or op == 0xA7 or op == 0xAE or op == 0xAF)
            while R[1] ~= 0 do
                once()
                R[1] = band(R[1] - 1, 0xFFFF)
                if cmpop then
                    if rep == 0xF3 and ZF == 0 then break end
                    if rep == 0xF2 and ZF == 1 then break end
                end
            end
        else once() end
    elseif op == 0xA8 then logic(band(r8(0), fetch8()), 8)
    elseif op == 0xA9 then logic(band(R[0], fetch16()), 16)
    elseif op >= 0xB0 and op <= 0xB7 then w8(op - 0xB0, fetch8())
    elseif op >= 0xB8 and op <= 0xBF then R[op - 0xB8] = fetch16()
    elseif op == 0xC2 then local n = fetch16(); ip = pop(); R[4] = band(R[4] + n, 0xFFFF)
    elseif op == 0xC3 then ip = pop()
    elseif op == 0xC4 or op == 0xC5 then
        decode_modrm()
        R[m_reg] = rw(m_seg, m_off); local sg = rw(m_seg, m_off + 2)
        if op == 0xC4 then S[0] = sg else S[3] = sg end
    elseif op == 0xC6 or op == 0xC7 then
        decode_modrm(); local w = op == 0xC6 and 8 or 16
        set_rm(w, w == 8 and fetch8() or fetch16())
    elseif op == 0xCA then local n = fetch16(); ip = pop(); S[1] = pop(); R[4] = band(R[4] + n, 0xFFFF)
    elseif op == 0xCB then ip = pop(); S[1] = pop()
    elseif op == 0xCC then do_int(3)
    elseif op == 0xCD then do_int(fetch8())
    elseif op == 0xCF then ip = pop(); S[1] = pop(); setflags(pop())
    elseif op >= 0xD0 and op <= 0xD3 then
        decode_modrm(); local w = band(op, 1) == 0 and 8 or 16
        local n = op < 0xD2 and 1 or band(R[1], 0xFF)
        set_rm(w, shift(m_reg, get_rm(w), n, w))
    elseif op == 0xD4 then local b = fetch8(); local al = r8(0); w8(4, math.floor(al / b)); w8(0, al % b); setszp(r8(0), 8)
    elseif op == 0xD5 then local b = fetch8(); w8(0, r8(0) + r8(4) * b); w8(4, 0); setszp(r8(0), 8)
    elseif op == 0xD6 then w8(0, CF == 1 and 0xFF or 0)
    elseif op == 0xD7 then w8(0, rb(segover or S[3], R[3] + r8(0)))
    elseif op >= 0xD8 and op <= 0xDF then decode_modrm()
    elseif op >= 0xE0 and op <= 0xE3 then
        local d = s8(fetch8())
        local take
        if op == 0xE3 then take = R[1] == 0
        else
            R[1] = band(R[1] - 1, 0xFFFF)
            if op == 0xE2 then take = R[1] ~= 0
            elseif op == 0xE1 then take = R[1] ~= 0 and ZF == 1
            else take = R[1] ~= 0 and ZF == 0 end
        end
        if take then ip = band(ip + d, 0xFFFF) end
    elseif op == 0xE4 then local p = fetch8(); w8(0, X.ports_in[p] and X.ports_in[p]() or 0)
    elseif op == 0xE5 then local p = fetch8(); R[0] = X.ports_in[p] and X.ports_in[p]() or 0
    elseif op == 0xE6 then local p = fetch8(); if X.ports_out[p] then X.ports_out[p](r8(0)) end
    elseif op == 0xE7 then local p = fetch8(); if X.ports_out[p] then X.ports_out[p](r8(0)) end
    elseif op == 0xE8 then local d = s16(fetch16()); push(ip); ip = band(ip + d, 0xFFFF)
    elseif op == 0xE9 then local d = s16(fetch16()); ip = band(ip + d, 0xFFFF)
    elseif op == 0xEA then local o = fetch16(); S[1] = fetch16(); ip = o
    elseif op == 0xEB then local d = s8(fetch8()); ip = band(ip + d, 0xFFFF)
    elseif op == 0xEC then w8(0, X.ports_in[R[2]] and X.ports_in[R[2]]() or 0)
    elseif op == 0xED then R[0] = X.ports_in[R[2]] and X.ports_in[R[2]]() or 0
    elseif op == 0xEE then if X.ports_out[R[2]] then X.ports_out[R[2]](r8(0)) end
    elseif op == 0xEF then if X.ports_out[R[2]] then X.ports_out[R[2]](r8(0)) end
    elseif op == 0xF4 then X.halted = true
    elseif op == 0xF5 then CF = 1 - CF
    elseif op == 0xF6 or op == 0xF7 then
        decode_modrm(); local w = op == 0xF6 and 8 or 16
        local r = m_reg
        if r == 0 or r == 1 then logic(band(get_rm(w), w == 8 and fetch8() or fetch16()), w)
        elseif r == 2 then set_rm(w, bnot(get_rm(w)))
        elseif r == 3 then local v = get_rm(w); set_rm(w, sub(0, v, 0, w)); CF = v ~= 0 and 1 or 0
        else
            local v = get_rm(w)
            if w == 8 then
                local al = r8(0)
                if r == 4 then local p = al * v; R[0] = p; CF = rshift(p, 8) ~= 0 and 1 or 0; OF = CF
                elseif r == 5 then local p = s8(al) * s8(v); R[0] = band(p, 0xFFFF); CF = (p < -128 or p > 127) and 1 or 0; OF = CF
                elseif r == 6 then
                    local a = R[0]
                    local q = v ~= 0 and math.floor(a / v) or 256
                    if q > 255 then do_int(0) else R[0] = bor(lshift(a - q * v, 8), q) end
                else
                    local a, d = s16(R[0]), s8(v)
                    local q = d ~= 0 and (a / d) or 1000
                    q = q < 0 and math.ceil(q) or math.floor(q)
                    if q > 127 or q < -128 then do_int(0) else R[0] = bor(lshift(band(a - q * d, 0xFF), 8), band(q, 0xFF)) end
                end
            else
                if r == 4 then local p = R[0] * v; R[0] = band(p, 0xFFFF); R[2] = band(math.floor(p / 65536), 0xFFFF); CF = R[2] ~= 0 and 1 or 0; OF = CF
                elseif r == 5 then
                    local p = s16(R[0]) * s16(v)
                    local u = p < 0 and p + 4294967296 or p
                    R[0] = u % 65536; R[2] = math.floor(u / 65536) % 65536
                    CF = (p < -32768 or p > 32767) and 1 or 0; OF = CF
                elseif r == 6 then
                    local n = R[2] * 65536 + R[0]
                    local q = v ~= 0 and math.floor(n / v) or 0x10000
                    if q > 0xFFFF then do_int(0) else R[0] = q; R[2] = n - q * v end
                else
                    local n = R[2] * 65536 + R[0]
                    if n >= 2147483648 then n = n - 4294967296 end
                    local d = s16(v)
                    local q = d ~= 0 and (n / d) or 100000
                    q = q < 0 and math.ceil(q) or math.floor(q)
                    if q > 32767 or q < -32768 then do_int(0) else R[0] = band(q, 0xFFFF); R[2] = band(n - q * d, 0xFFFF) end
                end
            end
        end
    elseif op == 0xF8 then CF = 0 elseif op == 0xF9 then CF = 1
    elseif op == 0xFA then IF = 0 elseif op == 0xFB then IF = 1
    elseif op == 0xFC then DF = 0 elseif op == 0xFD then DF = 1
    elseif op == 0xFE then
        decode_modrm(); local v = get_rm(8); local c = CF
        if m_reg == 0 then set_rm(8, add(v, 1, 0, 8)) else set_rm(8, sub(v, 1, 0, 8)) end
        CF = c
    elseif op == 0xFF then
        decode_modrm()
        local r = m_reg
        if r == 0 then local c = CF; set_rm(16, add(get_rm(16), 1, 0, 16)); CF = c
        elseif r == 1 then local c = CF; set_rm(16, sub(get_rm(16), 1, 0, 16)); CF = c
        elseif r == 2 then local t = get_rm(16); push(ip); ip = t
        elseif r == 3 then local o, sg = rw(m_seg, m_off), rw(m_seg, m_off + 2); push(S[1]); push(ip); ip = o; S[1] = sg
        elseif r == 4 then
            ip = get_rm(16)
            if X.dispatch_hook and m_mod == 0 and m_rm == 7 then X.dispatch_hook(X) end
        elseif r == 5 then local o, sg = rw(m_seg, m_off), rw(m_seg, m_off + 2); ip = o; S[1] = sg
        else push(get_rm(16)) end
    else
        error(string.format("x86: unimplemented opcode %02X at %04X:%04X", op, S[1], startip))
    end
end

function X.get_ip() return ip end
function X.set_ip(v) ip = v end
function X.steps() return steps end

return X

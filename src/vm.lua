-- Starflight Forth virtual machine.
--
-- STARFLT.COM is an indirect-threaded Forth system.  Everything the game does
-- is a chain of 16-bit "word" pointers; the only real machine code are the
-- ~200 primitives ("code words") that the inner interpreter jumps to.  This
-- file is a Lua port of the inner interpreter and of those primitives.  It is
-- a port of src/emul/call.c from the starflight-reverse project, redone from
-- the disassembly of each primitive.
--
-- Registers of the original machine that matter here:
--   si  Forth instruction pointer      sp  parameter stack
--   bp  return stack                   di  user area ("OPERATOR"), constant
--   bx  address of the code field of the word being executed

local ffi = require("ffi")
local bit = require("bit")
local band, bor, bxor, lshift, rshift, arshift =
    bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift, bit.arshift

local M = {}

-- 1 MB real-mode address space plus a little slack for segment:offset overflow
local mem = ffi.new("uint8_t[?]", 0x110000 + 0x10000)
M.mem = mem

local CS = 0x192                -- the COM file lives in segment 0x192
local DSB = CS * 16             -- linear address of offset 0
M.CS, M.DSB = CS, DSB

-- ---------------------------------------------------------------------------
-- memory access
-- ---------------------------------------------------------------------------
local function rd8(o) return mem[DSB + o] end
local function wr8(o, v) mem[DSB + o] = v end
local function rd16(o) return mem[DSB + o] + mem[DSB + o + 1] * 256 end
local function wr16(o, v)
    mem[DSB + o] = band(v, 0xFF)
    mem[DSB + o + 1] = band(rshift(v, 8), 0xFF)
end

-- far (segment:offset) access; hooks let the video code intercept A000..BFFF
local function lin(seg, off) return band(seg * 16 + off, 0xFFFFF) end
local lrd8, lwr8, lrd16, lwr16
local video = nil                 -- EGA model; owns segment A000..AFFF
function M.set_video(v) video = v end

lrd8 = function(seg, off)
    local a = lin(seg, off)
    if video and a >= 0xA0000 and a < 0xB0000 then return video.read(a - 0xA0000) end
    return mem[a]
end
lwr8 = function(seg, off, v)
    local a = lin(seg, off)
    if video and a >= 0xA0000 and a < 0xB0000 then video.write(a - 0xA0000, band(v, 0xFF)); return end
    mem[a] = band(v, 0xFF)
end
lrd16 = function(seg, off)
    return lrd8(seg, off) + lrd8(seg, off + 1) * 256
end
lwr16 = function(seg, off, v)
    lwr8(seg, off, v)
    lwr8(seg, off + 1, rshift(v, 8))
end

M.rd8, M.wr8, M.rd16, M.wr16 = rd8, wr8, rd16, wr16
M.lrd8, M.lwr8, M.lrd16, M.lwr16 = lrd8, lwr8, lrd16, lwr16
M.lin = lin

local function s16(x) if x >= 0x8000 then return x - 0x10000 end return x end
local function s8(x) if x >= 0x80 then return x - 0x100 end return x end
M.s16, M.s8 = s16, s8

-- ---------------------------------------------------------------------------
-- machine state
-- ---------------------------------------------------------------------------
local si, sp, bp, di = 0x129, 0, 0, 0
M.yield = false          -- set by a primitive that must wait (keyboard)
M.halted = false

function M.getsi() return si end
function M.setsi(v) si = band(v, 0xFFFF) end
function M.getsp() return sp end
function M.setsp(v) sp = band(v, 0xFFFF) end
function M.getbp() return bp end
function M.setbp(v) bp = band(v, 0xFFFF) end
function M.getdi() return di end
function M.set_di(v) di = band(v, 0xFFFF) end

local function push(v)
    sp = band(sp - 2, 0xFFFF)
    mem[DSB + sp] = band(v, 0xFF)
    mem[DSB + sp + 1] = band(rshift(v, 8), 0xFF)
end
local function pop()
    local v = mem[DSB + sp] + mem[DSB + sp + 1] * 256
    sp = band(sp + 2, 0xFFFF)
    return v
end
local function rpush(v)
    bp = band(bp - 2, 0xFFFF)
    wr16(bp, v)
end
local function rpop()
    local v = rd16(bp)
    bp = band(bp + 2, 0xFFFF)
    return v
end
M.push, M.pop, M.rpush, M.rpop = push, pop, rpush, rpop

-- primitives, keyed by the code address stored in a word's code field
local P = {}
M.P = P
local names = {}
pcall(function() names = require("names1") end)
M.names = names

function M.def(addr, fn) P[addr] = fn end

local function wordname(pfa) return names[pfa] or string.format("W%04X", pfa) end
M.wordname = wordname

-- ---------------------------------------------------------------------------
-- the generic "defining word" stub:  code field = CALL 0x1649, Forth follows
-- ---------------------------------------------------------------------------
local function make_paramcall(c)
    return function(bx)
        bp = band(bp - 2, 0xFFFF)
        wr16(bp, si)
        si = band(c + 3, 0xFFFF)
        push(bx + 2)
    end
end

local overlay_hook = nil           -- set by overlay code for overlay-resident machine code
function M.set_overlay_hook(f) overlay_hook = f end

local function unknown(c, bx)
    local f
    if mem[DSB + c] == 0xE8 and band(c + 3 + rd16(c + 1), 0xFFFF) == 0x1649 then
        f = make_paramcall(c)
        P[c] = f
        return f
    end
    if overlay_hook then
        f = overlay_hook(c, bx)
        if f then return f end
    end
    error(string.format("unported code word: code=%04X word=%04X (%s) si=%04X sp=%04X",
        c, bx + 2, wordname(bx + 2), si, sp))
end

-- execute the word whose code field is at bx
-- Colon-word hooks: hooks[cfa] = function() -> true to skip the word.  Used for
-- optional patches (see game.lua); empty during the verification runs.
local hooks = {}
M.hooks = hooks
local tracefn = nil
local function exec(bx)
    local c = rd16(bx)
    if tracefn then tracefn(bx, c) end
    if c == 0x224C and hooks[bx] and hooks[bx]() then return end
    local f = P[c] or unknown(c, bx)
    f(bx)
end
M.exec = exec

-- ---------------------------------------------------------------------------
-- inner interpreter
-- ---------------------------------------------------------------------------
M.trace = false
function M.set_trace(f) tracefn = f; M.trace = f ~= nil end

function M.run(maxsteps)
    local steps = maxsteps
    M.yield = false
    while steps > 0 do
        steps = steps - 1
        local w = mem[DSB + si] + mem[DSB + si + 1] * 256
        si = band(si + 2, 0xFFFF)
        local c = mem[DSB + w] + mem[DSB + w + 1] * 256
        if tracefn then tracefn(w, c) end
        if c == 0x224C and not (hooks[w] and hooks[w]()) then   -- colon definition
            bp = band(bp - 2, 0xFFFF)
            mem[DSB + bp] = band(si, 0xFF)
            mem[DSB + bp + 1] = rshift(si, 8)
            si = band(w + 2, 0xFFFF)
        elseif c ~= 0x224C then
            local f = P[c] or unknown(c, w)
            f(w)
            if M.yield or M.halted then return steps end
        end
    end
    return 0
end

-- Run a Forth word to completion from inside a Lua primitive (used by the slot menu).
local STOP_CFA = 0x58                          -- scratch cell holding the code address below
P[0x7F30] = function() M.stop = true; M.yield = true end
function M.call(cfa)
    local saved = si
    wr16(STOP_CFA, 0x7F30)
    wr16(0x40, cfa); wr16(0x42, STOP_CFA)
    si = 0x40
    M.stop = false
    while not M.stop and not M.halted do M.run(100000) end
    si = saved
end

-- ---------------------------------------------------------------------------
-- core primitives
-- ---------------------------------------------------------------------------
-- threading / control
P[0x224C] = function(bx) rpush(si); si = band(bx + 2, 0xFFFF) end                 -- :
P[0x1692] = function() si = rpop() end                                             -- EXIT
P[0x1662] = function() si = band(si + rd16(si), 0xFFFF) end                       -- BRANCH
P[0x15FC] = function()                                                              -- 0BRANCH
    if pop() == 0 then si = band(si + rd16(si), 0xFFFF) else si = band(si + 2, 0xFFFF) end
end
P[0x175F] = function() push(rd16(si)); si = band(si + 2, 0xFFFF) end              -- LIT
P[0x1618] = function()                                                              -- 2LIT
    push(rd16(si)); push(rd16(band(si + 2, 0xFFFF))); si = band(si + 4, 0xFFFF)
end
P[0x1684] = function() exec(band(pop() - 2, 0xFFFF)) end                          -- EXECUTE
P[0x1675] = function() exec(pop()) end                                              -- CFAEXEC
P[0x3A39] = function() exec(band(rd16(pop()) - 2, 0xFFFF)) end                     -- @EXECUTE
P[0x1536] = function()                                                              -- (>CODE)
    error("(>CODE): embedded machine code is not supported")
end
P[0x1548] = function()                                                              -- (;VIA)
    local a = rd16(si)
    si = band(a + 2, 0xFFFF)
end
P[0x174C] = function() wr16(bp + 2, rd16(bp)) end                                  -- LEAVE
P[0x15BA] = function()                                                              -- (DO)
    local idx, lim = pop(), pop()
    rpush(lim); rpush(idx)
end
P[0x15D2] = function()                                                              -- (LOOP)
    local ax = band(rd16(bp) + 1, 0xFFFF)
    if s16(ax) >= s16(rd16(bp + 2)) then
        bp = band(bp + 4, 0xFFFF); si = band(si + 2, 0xFFFF)
    else
        wr16(bp, ax); si = band(si + rd16(si), 0xFFFF)
    end
end
P[0x155E] = function()                                                              -- (+LOOP)
    local step = pop()
    local ax = band(rd16(bp) + step, 0xFFFF)
    local lim = s16(rd16(bp + 2))
    local done
    if step >= 0x8000 then done = s16(ax) < lim else done = s16(ax) >= lim end
    if done then
        bp = band(bp + 4, 0xFFFF); si = band(si + 2, 0xFFFF)
    else
        wr16(bp, ax); si = band(si + rd16(si), 0xFFFF)
    end
end
P[0x1593] = function()                                                              -- (/LOOP)
    local ax = band(pop() + rd16(bp), 0xFFFF)
    if ax >= rd16(bp + 2) then
        bp = band(bp + 4, 0xFFFF); si = band(si + 2, 0xFFFF)
    else
        wr16(bp, ax); si = band(si + rd16(si), 0xFFFF)
    end
end
P[0x0E52] = function() push(rd16(bp)) end                                          -- I
P[0x0E62] = function() push(rd16(bp + 2)) end                                      -- I'
P[0x0E70] = function() push(rd16(bp + 4)) end                                      -- J
P[0x0EA4] = function() push(rd16(bp)) end                                          -- R@
P[0x0E92] = function() push(rpop()) end                                            -- R>
P[0x0DB6] = function() rpush(pop()) end                                            -- >R
P[0x0EC8] = function() bp = rd16(di + 2) end                                       -- RP!
P[0x0ED8] = function() push(bp) end                                                -- RP@
P[0x0F05] = function() sp = rd16(di) end                                           -- SP!
P[0x0F14] = function() push(sp) end                                                -- SP@
P[0x0AD1] = function() push(di) end                                                -- ME
P[0x0C17] = function() push(CS) end                                                -- (CS?)
P[0x49C2] = function() push(CS) end                                                -- @DS
P[0x16A3] = function()                                                              -- GO ( addr -- ): jump to machine code
    local target = pop()
    if target == 0x100 then                       -- restart: the 16-byte start-up code of the COM file
        sp = band(rd16(0x705) + 0x100, 0xFFFF)
        bp = band(sp + 0x80, 0xFFFF)
        si = 0x129
        di = band(rd16(si + 2) + 2, 0xFFFF)
    else                                          -- 0000 = INT 20h: back to DOS
        M.halted = true; M.exit_to = target
    end
end

-- data-ish words
P[0x1D29] = function(bx) push(band(bx + 2, 0xFFFF)) end                           -- variable/array
P[0x2214] = function(bx) push(rd16(bx + 2)) end                                    -- constant
P[0x1792] = function(bx) push(band(rd16(bx + 2) + di, 0xFFFF)) end                 -- user variable
P[0x17B7] = function(bx)                                                            -- vectored word
    local t = rd16(band(bx + 2, 0xFFFF))
    exec(band(rd16(band(t + di, 0xFFFF)) - 2, 0xFFFF))
end
P[0x21C9] = function() end                                                          -- stack check (never fails here)

-- stack
P[0x0E34] = function() sp = band(sp + 2, 0xFFFF) end                               -- DROP
P[0x0DE0] = function() sp = band(sp + 4, 0xFFFF) end                               -- 2DROP
P[0x0E43] = function() push(rd16(sp)) end                                          -- DUP
P[0x0DF2] = function() local a, b = rd16(sp + 2), rd16(sp); push(a); push(b) end   -- 2DUP
P[0x0DCA] = function() local a = rd16(sp); if a ~= 0 then push(a) end end          -- ?DUP
P[0x0E81] = function() push(rd16(sp + 2)) end                                      -- OVER
P[0x0EF4] = function() local a, b = pop(), pop(); push(a); push(b) end             -- SWAP
P[0x0E08] = function()                                                              -- 2SWAP
    local a, b, c, d = pop(), pop(), pop(), pop()
    push(b); push(a); push(d); push(c)
end
P[0x0EB5] = function() local c, b, a = pop(), pop(), pop(); push(b); push(c); push(a) end -- ROT
P[0x0F22] = function() push(0) end
P[0x0F30] = function() push(1) end
P[0x0F3F] = function() push(2) end

-- arithmetic / logic
P[0x0F74] = function() push(band(pop() + pop(), 0xFFFF)) end                       -- +
P[0x0F94] = function() local b = pop(); push(band(pop() - b, 0xFFFF)) end          -- -
P[0x0FB5] = function() push(band(pop() * pop(), 0xFFFF)) end                       -- *
P[0x0F85] = function()                                                              -- +!
    local a, v = pop(), pop()
    wr16(a, band(rd16(a) + v, 0xFFFF))
end
P[0x0FE9] = function() push(band(pop() + 1, 0xFFFF)) end
P[0x0FF8] = function() push(band(pop() - 1, 0xFFFF)) end
P[0x1007] = function() push(band(pop() * 2, 0xFFFF)) end
P[0x1017] = function() push(band(pop() + 2, 0xFFFF)) end
P[0x1027] = function() push(band(pop() - 2, 0xFFFF)) end
P[0x1037] = function() push(band(arshift(s16(pop()), 1), 0xFFFF)) end              -- 2/
P[0x1047] = function() push(band(pop() * 4, 0xFFFF)) end                           -- 4*
P[0x4984] = function() push(band(pop() + 3, 0xFFFF)) end                           -- 3+
P[0x4935] = function() push(rshift(pop(), 4)) end                                  -- 16/
P[0x4949] = function() push(band(pop() * 16, 0xFFFF)) end                          -- 16*
P[0x11C8] = function() push(band(-pop(), 0xFFFF)) end                              -- NEGATE
P[0x12F7] = function() push(band(pop(), pop())) end                                -- AND
P[0x1340] = function() push(bor(pop(), pop())) end                                 -- OR
P[0x1366] = function() push(bxor(pop(), pop())) end                                -- XOR
P[0x1309] = function() push(pop() == 0 and 1 or 0) end                             -- NOT
P[0x128B] = function() push(pop() == 0 and 1 or 0) end                             -- 0=
P[0x127A] = function() push(pop() >= 0x8000 and 1 or 0) end                        -- 0<
P[0x12A1] = function() local v = pop(); push((v ~= 0 and v < 0x8000) and 1 or 0) end -- 0>
P[0x1261] = function() push(pop() == pop() and 1 or 0) end                         -- =
P[0x1248] = function() local b, a = pop(), pop(); push(s16(a) < s16(b) and 1 or 0) end -- <
P[0x122F] = function() local b, a = pop(), pop(); push(s16(a) > s16(b) and 1 or 0) end -- >
P[0x12E1] = function() local b, a = pop(), pop(); push(a < b and 1 or 0) end       -- U<
P[0x1355] = function()                                                              -- TOGGLE
    local v, a = pop(), pop()
    wr8(a, bxor(rd8(a), band(v, 0xFF)))
end
P[0x1508] = function() push(rd16(sp) >= 0x8000 and 0xFFFF or 0) end                -- S->D
P[0x1067] = function()                                                              -- D+
    local hi1, lo1, hi2, lo2 = pop(), pop(), pop(), pop()
    local lo = lo1 + lo2
    local hi = band(hi1 + hi2 + (lo >= 0x10000 and 1 or 0), 0xFFFF)
    push(band(lo, 0xFFFF)); push(hi)
end
P[0x10B9] = function()                                                              -- DNEGATE
    local hi, lo = pop(), pop()
    local nlo = band(-lo, 0xFFFF)
    local nhi = band(-hi - (lo ~= 0 and 1 or 0), 0xFFFF)
    push(nlo); push(nhi)
end
P[0x4B08] = function()                                                              -- D2*
    local hi, lo = pop(), pop()
    local nlo = band(lo * 2, 0xFFFF)
    local nhi = band(hi * 2 + (lo >= 0x8000 and 1 or 0), 0xFFFF)
    push(nlo); push(nhi)
end
P[0x495E] = function()                                                              -- D16*
    local hi, lo = pop(), pop()
    local v = (hi * 65536 + lo) * 16
    push(band(v, 0xFFFF)); push(band(math.floor(v / 65536), 0xFFFF))
end
P[0x11D8] = function()                                                              -- U*
    local v = pop() * pop()
    push(band(v, 0xFFFF)); push(band(math.floor(v / 65536), 0xFFFF))
end
-- A divide error raises INT 0; the game installs a handler (SET0/) that returns
-- with AX = DX = 0, so the result of the offending division is simply zero.

P[0x11ED] = function()                                                              -- U/MOD
    local d, hi, lo = pop(), pop(), pop()
    local n = hi * 65536 + lo
    local q = d ~= 0 and math.floor(n / d) or 0x10000
    if q > 0xFFFF then push(0); push(0); return end
    push(n - q * d); push(q)
end
local function idiv(a, b)       -- truncating signed division
    local q = a / b
    q = q < 0 and math.ceil(q) or math.floor(q)
    return q, a - q * b
end
P[0x0F4E] = function()                                                              -- /
    local b, a = s16(pop()), s16(pop())
    if b == 0 then push(0); return end
    local q = idiv(a, b)
    if q > 32767 or q < -32768 then push(0); return end
    push(band(q, 0xFFFF))
end
P[0x0F62] = function()                                                              -- /MOD
    local b, a = s16(pop()), s16(pop())
    if b == 0 then push(0); push(0); return end
    local q, r = idiv(a, b)
    if q > 32767 or q < -32768 then push(0); push(0); return end
    push(band(r, 0xFFFF)); push(band(q, 0xFFFF))
end
P[0x4910] = function()                                                              -- 2^N
    local cx = band(pop() + 1, 0xFFFF)               -- stc ; inc cx ; jcxz ; rcl ax,cl  (a 17-bit ring)
    if cx == 0 then push(0); return end
    local pos = (16 + band(cx, 0xFF)) % 17
    push(pos == 16 and 0 or lshift(1, pos))
end
P[0x4AF3] = function()                                                              -- +BIT (population count)
    local a, n = pop(), 0
    for i = 0, 15 do n = n + band(rshift(a, i), 1) end
    push(n)
end
P[0x4ABB] = function()                                                              -- FRND
    local seed = rd16(0x4AB0)
    local v = band(s16(seed) * 0x7ABD + 0x1B0F, 0xFFFF)
    wr16(0x4AB0, v)
    push(v)
end
P[0x4B17] = function()                                                              -- EASY-BITS (integer sqrt step)
    local cx, ax, dx, bx = pop(), pop(), pop(), pop()
    repeat
        local full = (dx * 65536 + bx) * 4                 -- dx:bx <<= 2 (high bits fall off)
        dx = band(math.floor(full / 65536), 0xFFFF)
        bx = band(full, 0xFFFF)
        dx = band(dx - ax, 0xFFFF)
        if dx >= 0x8000 then                               -- negative: undo
            dx = band(dx + ax, 0xFFFF)
            ax = band(ax * 2 - 1, 0xFFFF)
        else
            ax = band((ax + 1) * 2 + 1, 0xFFFF)
        end
        cx = band(cx - 1, 0xFFFF)
    until cx == 0
    push(bx); push(dx); push(ax)
end

-- memory
P[0x0BB0] = function() push(rd16(pop())) end                                       -- @
P[0x0BE1] = function() local a = pop(); wr16(a, pop()) end                         -- !
P[0x0C94] = function() push(rd8(pop())) end                                        -- C@
P[0x0C60] = function() local a = pop(); wr8(a, band(pop(), 0xFF)) end              -- C!
P[0x0C3A] = function() local a = pop(); push(rd16(a + 2)); push(rd16(a)) end       -- 2@
P[0x0C24] = function() local a, lo, hi = pop(), pop(), pop(); wr16(a, lo); wr16(a + 2, hi) end -- 2!
P[0x4997] = function() local a = pop(); push(rd16(a)); push(rd8(a + 2)) end        -- 1.5@
P[0x49AE] = function() local a = pop(); wr8(a + 2, band(pop(), 0xFF)); wr16(a, pop()) end -- 1.5!
P[0x4BC5] = function() push(band(s8(rd8(pop())), 0xFFFF)) end                      -- +-@
P[0x0D10] = function()                                                              -- CMOVE
    local n, dst, src = pop(), pop(), pop()
    if band(n, 1) == 1 then wr8(dst, rd8(src)); dst = dst + 1; src = src + 1; n = n - 1 end
    for i = 0, n - 1 do mem[DSB + band(dst + i, 0xFFFF)] = mem[DSB + band(src + i, 0xFFFF)] end
end
P[0x0CE4] = function()                                                              -- CMOVE>
    local n, dst, src = pop(), pop(), pop()
    for i = n - 1, 0, -1 do mem[DSB + band(dst + i, 0xFFFF)] = mem[DSB + band(src + i, 0xFFFF)] end
end
P[0x0D35] = function()                                                              -- FILL
    local v, n, a = band(pop(), 0xFF), pop(), pop()
    for i = 0, n - 1 do mem[DSB + band(a + i, 0xFFFF)] = v end
end
P[0x0D7C] = function() push(band((pop() - CS) * 16, 0xFFFF)) end                   -- SEG>ADDR
P[0x0D9C] = function() push(band(rshift(pop(), 4) + CS, 0xFFFF)) end               -- ADDR>SEG

-- "segment" words addressing 64K pages: the argument is a 4-bit page number
-- turned into a segment value (al*16 in the high byte).
local function pagesel(v) return lshift(band(lshift(band(v, 0xFF), 4), 0xFF), 8) end
P[0x0BBF] = function() local seg, off = pagesel(pop()), pop(); push(lrd16(seg, off)) end  -- @L
P[0x0BF1] = function() local seg, off, v = pagesel(pop()), pop(), pop(); lwr16(seg, off, v) end -- !L
P[0x0CA7] = function() local seg, off = pagesel(pop()), pop(); push(lrd8(seg, off)) end   -- C@L
P[0x0C71] = function() local seg, off, v = pagesel(pop()), pop(), pop(); lwr8(seg, off, v) end -- C!L

P[0x2EA4] = function() local off, seg = pop(), pop(); push(lrd16(seg, off)) end    -- L@
P[0x2EB8] = function() local off, seg = pop(), pop(); lwr16(seg, off, pop()) end   -- L!
P[0x2ECD] = function() local off, seg = pop(), pop(); push(lrd8(seg, off)) end     -- LC@
P[0x2EE5] = function() local off, seg = pop(), pop(); lwr8(seg, off, pop()) end    -- LC!
P[0x49F0] = function() local off, seg = pop(), pop(); push(band(s8(lrd8(seg, off)), 0xFFFF)) end -- L+-@
P[0x4BD9] = function()                                                              -- L1.5@
    local off, seg = pop(), pop()
    push(lrd16(seg, off)); push(lrd8(seg, off + 2))
end
P[0x2EFE] = function()                                                              -- LCMOVE
    local n, doff, dseg, soff, sseg = pop(), pop(), pop(), pop(), pop()
    for i = 0, n - 1 do lwr8(dseg, doff + i, lrd8(sseg, soff + i)) end
end
P[0x48DC] = function()                                                              -- <LCMOVE
    local n, doff, dseg, soff, sseg = pop(), pop(), pop(), pop(), pop()
    for i = n - 1, 0, -1 do lwr8(dseg, doff + i, lrd8(sseg, soff + i)) end
end
P[0x2F51] = function()                                                              -- LWSCAN
    local v, n = pop(), pop()
    if n == 0 then sp = band(sp + 4, 0xFFFF); push(0); return end
    local off, seg = pop(), pop()
    while n > 0 do
        local x = lrd16(seg, off)
        off = band(off + 2, 0xFFFF); n = n - 1
        if x == v then break end
    end
    off = band(off - 2, 0xFFFF)
    if lrd16(seg, off) == v then push(off); push(1) else push(n) end
end

-- ---------------------------------------------------------------------------
-- disk-cache helpers (Forth block buffers live in far segments)
-- ---------------------------------------------------------------------------
local function lxchg16(es, a, b)         -- swap two words in segment es
    local x, y = lrd16(es, a), lrd16(es, b)
    lwr16(es, a, y); lwr16(es, b, x)
end
local function lxchg8(es, a, b)
    local x, y = lrd8(es, a), lrd8(es, b)
    lwr8(es, a, y); lwr8(es, b, x)
end
P[0x3048] = function()                                                              -- (BUFFER)
    local cx = pop()
    local ax = 0
    local es = rd16(0x2C84)                                                         -- PREV
    if lrd16(es, 6) == cx then
        if lrd8(es, 3) == 0 then ax = 1 end
    else
        es = rd16(0x2CBE)                                                           -- USE
        if lrd16(es, 6) == cx and lrd8(es, 3) == 0 then
            ax = 1
            local prev = rd16(0x2C84)
            wr16(0x2C84, es)
            wr16(0x2CBE, prev)
        end
    end
    if ax == 0 then push(cx) else push(es); wr16(0x2C6C, rd16(0x2C84)) end
    push(ax)
end
P[0x30A8] = function()                                                              -- ADVANCE>DEF
    local ax = pop()
    if ax ~= 0 then
        local bx = ax - 2
        lxchg16(rd16(0x2C04), bx, ax)                                               -- BLKCACHE
        lxchg16(rd16(0x2C9D), bx, ax)                                               -- SEGCACHE
    end
end
P[0x7684] = function()                                                              -- PRIORITIZE
    local ax = pop()
    if ax == 0 then push(0); return end
    local bx = ax - 2
    lxchg16(rd16(0x54EA), bx, ax)                                                   -- LOISEG
    lxchg16(rd16(0x54F2), bx, ax)                                                   -- LOCSEC
    bx = rshift(bx, 1); ax = rshift(ax, 1)
    lxchg8(rd16(0x54EE), bx, ax)                                                    -- HIISEG
    push(band(bx * 2, 0xFFFF))
end
P[0x3672] = function() push(band(pop() + rd16(0x2C79), 0xFFFF)) end                -- W3672 (OFFSET +)
P[0x367F] = function()                                                              -- W367F
    local dx = pop()
    local cx = rd16(0x2B3A)                                                         -- #FILES
    local bx, ax, bpv = 0, 0, 0
    while cx ~= 0 do
        bpv = (cx - 1) * 2
        ax = band(dx - rd16(0x2D74 + bpv), 0xFFFF)
        if ax < 0x8000 and not (s16(rd16(0x2D4C + bpv)) < s16(ax)) then
            bx = bx + 1
            cx = 1
        end
        cx = cx - 1
    end
    push(ax); push(rshift(bpv, 1)); push(bx)
end
P[0x36BB] = function()                                                              -- W36BB
    local n = pop()
    local cx = rd8(n + 0x2D23)                                                      -- DRIVENUMBERS
    if cx == 0 then cx = rd16(0x2C15) end                                           -- DEFAULTDRV
    push(band(cx - 1, 0xFFFF))
end
P[0x4A15] = function()                                                              -- case table lookup
    local bx, ax = pop(), pop()
    local cx = rd16(bx); bx = bx + 2
    local dx = rd16(bx); bx = bx + 2
    for _ = 1, cx do
        if rd16(bx) == ax then dx = rd16(bx + 2); break end
        bx = bx + 4
    end
    push(dx)
end
P[0x1AC0] = function()                                                              -- W1AC0
    local bx = pop()
    push(band(rd8(bx) + rd8(bx + 1), 6) + 6)
end

-- string words
P[0x143A] = function()                                                              -- >UPPERCASE
    local n, a = pop(), pop()
    for i = 0, n - 1 do
        local c = rd8(a + i)
        if c >= 0x61 and c <= 0x7A then wr8(a + i, band(c, 0xDF)) end
    end
end
P[0x14BD] = function()                                                              -- DIGIT ( c base -- n 1 | 0 )
    local base, cfull = band(pop(), 0xFF), pop()            -- the asm only looks at DL and AL
    local c = band(cfull, 0xFF)
    local al = c - 0x30
    if al >= 0 then
        local ok = true
        if al > 9 then
            al = al - 7
            if al < 10 then ok = false end
        end
        if ok and al < base then push(al); push(bor(band(cfull, 0xFF00), 1)); return end   -- AH is left as it was
    end
    push(0)
end
P[0x22AB] = function()                                                              -- ENCLOSE
    local ax = band(pop(), 0xFF)
    local bx = pop()
    push(bx)
    local dx = 0
    while rd8(bx) == ax do bx = bx + 1; dx = dx + 1 end
    push(dx)
    if rd8(bx) == 0 then
        push(dx + 1); push(dx)
        return
    end
    while true do
        bx = bx + 1; dx = dx + 1
        local c = rd8(bx)
        if c == ax then push(dx); push(dx + 1); return end
        if c == 0 then push(dx); push(dx); return end
    end
end
P[0x1818] = function()                                                              -- (FIND)
    local bx, cx = pop(), pop()
    local n = rd8(cx)
    while bx ~= 0 do
        if band(rd8(bx), 0x3F) == n then
            local di, i = bx, 0
            local x
            repeat
                di = di + 1; i = i + 1
                x = bxor(rd8(di), rd8(cx + i))
            until x ~= 0
            if band(x, 0x7F) == 0 then
                push(di + 3); push(rd8(bx)); push(1)
                return
            end
        end
        bx = rd16(bx - 2)
    end
    push(0)
end

return M

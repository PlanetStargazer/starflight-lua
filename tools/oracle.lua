-- Reference run on the original machine code (dev tool).
--   luajit tools/oracle.lua out.log max_events [keys] [checkpoint_every]
-- Writes one line per Forth dispatch ("si bx sp bp") and periodic memory checksums.
package.path = "src/?.lua;tools/?.lua;" .. package.path
local ffi = require("ffi")
local bit = require("bit")
local vm = require("vm")
local dos = require("dos")
local hw = require("hw")
local ega = require("ega")
local video = require("video")
local X = require("x86")
local game = require("game")      -- also installs the video model
local snap = require("snap")
local SNAP, THREAD = os.getenv("SNAP"), os.getenv("THREAD")

local out, maxev, keys, every = arg[1], tonumber(arg[2]), arg[3] or "", tonumber(arg[4]) or 5000
local mem, DSB = vm.mem, vm.DSB
-- load the files exactly as the VM boot does, but do not touch the Forth registers
local com = game.readfile("games/sf1/STARFLT.COM")
ffi.fill(mem, 0x110000, 0)
ffi.copy(mem + DSB + 0x100, com, #com)
dos.addfile("A", game.readfile(os.getenv("SF_A") or "games/sf1/STARA.COM"), 256000)
dos.addfile("B", game.readfile(os.getenv("SF_B") or "games/sf1/STARB.COM"), 362496)
video.setmode(3)
mem[DSB], mem[DSB + 1] = 0xCD, 0x20          -- PSP: INT 20h
for _, k in ipairs(require("keys").parse(keys)) do hw.pushkey(k) end

local R, S = X.R, X.S
S[0], S[1], S[2], S[3] = 0x192, 0x192, 0x192, 0x192
R[4] = 0xFFFE
X.set_ip(0x100)
if SNAP then
    -- start from a snapshot taken from the Lua VM, at a Forth NEXT: SI -> test thread
    local st = snap.load(SNAP)
    R[4], R[5], R[7] = vm.getsp(), vm.getbp(), vm.getdi()
    R[6] = require("thread").install(vm.wr16, THREAD or "")
    X.set_ip(0x124)                 -- lodsw / mov bx,ax / jmp [bx]
    vm.setsp(R[4])
end

-- ports
X.ports_out[0x3C4] = function(v) ega.out(0x3C4, v) end
X.ports_out[0x3C5] = function(v) ega.out(0x3C5, v) end
X.ports_out[0x3CE] = function(v) ega.out(0x3CE, v) end
X.ports_out[0x3CF] = function(v) ega.out(0x3CF, v) end
X.ports_out[0x3D4] = function(v) ega.out(0x3D4, v) end
X.ports_out[0x3D5] = function(v) ega.out(0x3D5, v) end
X.ports_in[0x3DA] = function() return ega.inp(0x3DA) end
X.ports_in[0x3CF] = function() return ega.inp(0x3CF) end

local events = 0
-- PC speaker as the game programs it: PIT channel 2 divisor (two byte writes) and port 61h
local pit2, pit2_lo = nil, nil
X.ports_out[0x43] = function(v) if v == 0xB6 then pit2_lo = true end end
X.ports_out[0x42] = function(v)
    if pit2_lo == true then pit2 = v; pit2_lo = false
    elseif pit2_lo == false then hw.sound.divisor = pit2 + v * 256; pit2_lo = true end
end
local port61 = 0
X.ports_out[0x61] = function(v) port61 = v; hw.sound.on = bit.band(v, 3) == 3 end
X.ports_in[0x61] = function() return port61 end
local TICK = tonumber(os.getenv("TICK") or "3000")
if os.getenv('WATCH') then
    X.watch = 0x1920 + tonumber(os.getenv('WATCH'), 16)
    X.onwatch = function(v, seg, off) io.stderr:write(string.format('write %02X at event %d, ip=%04X\n', v, events, X.get_ip())) end
end

local function dumpmem(path)
    local fh = io.open(path, "wb")
    fh:write(require("ffi").string(mem + DSB, 0x10000))
    fh:close()
    fh = io.open(path .. ".full", "wb")
    fh:write(require("ffi").string(mem, 0xA0000))
    fh:close()
    fh = io.open(path .. ".ega", "wb")
    fh:write(require("ffi").string(ega.mem, 0x40000))
    fh:close()
end
local dump_at = tonumber(os.getenv("DUMP_AT") or "-1")
local f = assert(io.open(out, "w"))
local waiting = false
local idle = 0

-- software interrupts
X.int_handler = function(n, x)
    if n == 0x20 then x.halted = true; return true end
    if n == 0x16 then
        local ah = bit.rshift(R[0], 8)
        if ah == 1 then
            if #hw.keys == 0 then x.setflags(bit.bor(x.getflags(), 64)); waiting = true
            else
                x.setflags(bit.band(x.getflags(), bit.bnot(64)))
                local k = hw.keys[1]; R[0] = (k >= 256 and k or k)    -- peek
            end
        else
            if #hw.keys == 0 then waiting = true; R[0] = 0
            else
                local k = table.remove(hw.keys, 1)
                if k >= 256 then R[0] = bit.band(k, 0xFF00) else R[0] = k end   -- scan code in AH, ascii 0
            end
        end
        return true
    end
    local h = dos.handlers[n]
    if not h then return false end
    local r = {flags = x.getflags(), ax = R[0], bx = R[3], cx = R[1], dx = R[2], di = R[7], si_in = R[6], ds = S[3], es = S[0]}
    h(r)
    R[0], R[3], R[1], R[2], R[7] = r.ax % 65536, r.bx % 65536, r.cx % 65536, r.dx % 65536, r.di % 65536
    S[3], S[0] = r.ds, r.es
    return true
end

-- deterministic clock for TIME: replace the machine code by a fixed function of the event counter
X.hle[0x2A9A] = true
-- scratch variables and self-modified code of the original graphics routines are not compared
local SKIP = {{0xD500, 0xD5A8}, {0x5663, 0x5665}, {0x6A89, 0x6A8D}, {0x52BE, 0x52CB}, {0x5613, 0x5615},
    {0x561C, 0x561E}, {0x5625, 0x5627}, {0x562E, 0x5630}, {0x57B7, 0x57B9}, {0x57C2, 0x57C4},
    {0x57CE, 0x57D0}, {0x8860, 0x887C}, {0x86B0, 0x8700}, {0x48C6, 0x48CA}, {0x188, 0x196}, {0x1B8, 0x1C4}, {0x56BF, 0x56CF}, {0xE38A, 0xE398}}
local function skipped(a)
    for _, r in ipairs(SKIP) do if a >= r[1] and a < r[2] then return true end end
    return false
end
local function farsum()
    local h = 0
    local remseg = vm.rd16(0x52A5) * 16
    local arc, lline = remseg + 0xC5A, remseg + 0x8D0     -- self-modified code of the EGA driver (ARC, LLINE)
    for a = 0x11920, 0x9FFFF do
        if not ((a >= arc and a < arc + 2) or (a >= lline and a < lline + 0x14)) then h = (h * 31 + mem[a]) % 4294967291 end
    end
    return h
end
local function checksum(sp, bp)
    local h = 0
    for a = 0x100, 0xF800 do
        if not ((a >= sp - 0x100 and a < sp) or (a >= bp - 0x100 and a < bp) or skipped(a)) then h = (h * 31 + mem[DSB + a]) % 4294967291 end
    end
    for a = 0xB8000, 0xB8F9F do h = (h * 29 + mem[a]) % 4294967291 end
    h = (h * 37 + (hw.sound.on and 1 or 0) * 65536 + (hw.sound.divisor or 0)) % 4294967291
    do local musseg = vm.rd16(0x5071); if musseg ~= 0 then for o = 0, 0x31F do h = (h * 31 + vm.lrd8(musseg, o)) % 4294967291 end end end
    for p = 0, 0x3FFFF, 1 do
        local v = ega.mem[p]
        if v ~= 0 then h = (h * 33 + v + p) % 4294967291 end
    end
    return h
end

X.dispatch_hook = function(x)
    events = events + 1
    idle = 0
    if events > maxev then x.halted = true; return end
    f:write(string.format("%04x %04x %04x %04x %04x %04x\n", R[6], R[3], R[4], R[5], vm.rd16(R[4]), vm.rd16(R[4] + 2)))
    if events % every == 0 then f:write(string.format("# %d %d\n", events, checksum(R[4], R[5]))) end
    if events % TICK == 0 then
        -- deliver INT 1Ch: run the real interrupt routine until it returns here
        local fl, cs0, ip0, sp0 = x.getflags(), S[1], x.get_ip(), R[4]
        local seg0 = S[1]
        R[4] = (R[4] - 2) % 65536; vm.wr16(R[4], fl)
        R[4] = (R[4] - 2) % 65536; vm.wr16(R[4], cs0)
        R[4] = (R[4] - 2) % 65536; vm.wr16(R[4], ip0)
        x.set_ip(vm.lrd16(0, 0x1C * 4)); S[1] = vm.lrd16(0, 0x1C * 4 + 2)
        local guard = 0
        while not (R[4] == sp0 and S[1] == cs0 and x.get_ip() == ip0) do
            x.step(); guard = guard + 1
            if guard > 200000 then error("interrupt routine did not return") end
        end
    end
    if events == dump_at then dumpmem("/var/tmp/oracle.mem") end
end

local ok, err = pcall(function()
    while not X.halted and not waiting do
        local ip = X.get_ip()
        if S[1] == 0x192 and ip == 0x2A9A then
            -- TIME: deterministic
            local t = events * 3
            vm.wr16(0x18A, t % 65536); vm.wr16(0x188, math.floor(t / 65536) % 65536); vm.wr16(0x193, 0)
            R[4] = (R[4] - 2) % 65536; vm.wr16(R[4], 0x188)
            -- NEXT
            local ax = vm.rd16(R[6]); R[6] = (R[6] + 2) % 65536; R[0] = ax; R[3] = ax
            X.set_ip(vm.rd16(R[3]))
            X.dispatch_hook(X)
        else
            X.step()
            idle = idle + 1
            if idle > 20000000 then
                f:write(string.format("# stuck at %04X:%04X ax=%04X bx=%04X cx=%04X dx=%04X si=%04X di=%04X\n", S[1], X.get_ip(), R[0], R[3], R[1], R[2], R[6], R[7]))
                break
            end
        end
    end
end)
do local st = {} for i = 0, 7 do st[#st + 1] = string.format("%04x", vm.rd16(R[4] + i * 2)) end f:write(string.format("# final %d far %d stack %s\n", checksum(R[4], R[5]), farsum(), table.concat(st, " "))) end
f:write(string.format("# end %d %s\n", events, tostring(err)))
f:close()
print(ok, err, "events", events, "waiting", waiting)

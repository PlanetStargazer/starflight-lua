-- Same log as tools/oracle.lua, produced by the Lua VM.
--   luajit tools/vmlog.lua out.log max_events [keys] [checkpoint_every]
package.path = "src/?.lua;tools/?.lua;" .. package.path
local vm = require("vm")
local hw = require("hw")
local ega = require("ega")
local game = require("game")
local out, maxev, keys, every = arg[1], tonumber(arg[2]), arg[3] or "", tonumber(arg[4]) or 5000
game.boot("games/sf1", os.getenv("SF_A") and {stara = game.readfile(os.getenv("SF_A")), starb = game.readfile(os.getenv("SF_B"))} or nil)
local snap = require("snap")
local SNAP, SAVESNAP, THREAD = os.getenv("SNAP"), os.getenv("SAVESNAP"), os.getenv("THREAD")
if SNAP then
    snap.load(SNAP)
    vm.setsi(require("thread").install(vm.wr16, THREAD or ""))
end
for _, k in ipairs(require("keys").parse(keys)) do hw.pushkey(k) end
local mem, DSB = vm.mem, vm.DSB
local events = 0
local TICK = tonumber(os.getenv("TICK") or "3000")

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
vm.def(0x2A9A, function()
    local t = events * 3
    vm.wr16(0x18A, t % 65536); vm.wr16(0x188, math.floor(t / 65536) % 65536); vm.wr16(0x193, 0)
    vm.push(0x188)
end)
local stop = false
-- like the oracle, stop as soon as the game polls the keyboard with nothing queued
local orig_term = vm.P[0x25BC]
vm.P[0x25BC] = function(bx)
    if #hw.keys == 0 then vm.halted = true; return end
    orig_term(bx)
end
vm.set_trace(function(w, c)
    events = events + 1
    if events > maxev then stop = true; vm.halted = true; return end
    f:write(string.format("%04x %04x %04x %04x %04x %04x\n", vm.getsi(), w, vm.getsp(), vm.getbp(), vm.rd16(vm.getsp()), vm.rd16(vm.getsp() + 2)))
    if events % every == 0 then f:write(string.format("# %d %d\n", events, checksum(vm.getsp(), vm.getbp()))) end
    if events % TICK == 0 then require("music").tick() end
    if events == dump_at then dumpmem("/var/tmp/vm.mem") end
end)
local ok, err = pcall(function()
    while not vm.halted do
        vm.run(100000)
        if vm.yield then break end
    end
end)
if SAVESNAP then snap.save(SAVESNAP) end
do local st = {} for i = 0, 7 do st[#st + 1] = string.format("%04x", vm.rd16(vm.getsp() + i * 2)) end f:write(string.format("# final %d far %d stack %s\n", checksum(vm.getsp(), vm.getbp()), farsum(), table.concat(st, " "))) end
f:write(string.format("# end %d %s\n", events, tostring(err)))
f:close()
print(ok, err, "events", events, "yield", vm.yield)

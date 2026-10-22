-- luajit tools/forcedshot.lua snapdir "tokens" out.ppm : run a thread on the VM from a snapshot, save the screen
package.path = "src/?.lua;tools/?.lua;" .. package.path
local vm = require("vm")
local game = require("game")
local snap = require("snap")
local ega = require("ega")
local ffi = require("ffi")
game.boot("games/sf1")
snap.load(arg[1])
vm.setsi(require("thread").install(vm.wr16, arg[2]))
print(pcall(function() vm.run(20000000) end))
local buf = ffi.new("uint8_t[?]", 320 * 200 * 4); ega.render(buf)
local f = io.open(arg[3], "wb"); f:write("P6\n320 200\n255\n")
for i = 0, 320 * 200 - 1 do f:write(string.char(buf[i * 4], buf[i * 4 + 1], buf[i * 4 + 2])) end
f:close()

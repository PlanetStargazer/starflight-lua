package.path = "src/?.lua;" .. package.path
local vm = require("vm")
local game = require("game")
local hw = require("hw")
game.boot("games/sf1")
for c in (arg[2] or ""):gmatch(".") do hw.pushkey(c == "\n" and 13 or c:byte()) end
print(pcall(function() vm.run(tonumber(arg[1])) end))
print(string.format("OV# = %04X  OVA=%04X", vm.rd16(0x55A5), vm.rd16(0x5BF8 or 0)))

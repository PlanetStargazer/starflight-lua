package.path = "src/?.lua;" .. package.path
local vm = require("vm")
local game = require("game")
local hw = require("hw")
game.boot("games/sf1")
for _, k in ipairs(require("keys").parse("5 ENTER 2 3*SP")) do hw.pushkey(k) end
vm.run(20000000)
local seg = vm.rd16(0x5071)
print(string.format("MUSSEG=%04X", seg))
local f = io.open("/var/tmp/music.bin", "wb")
for i = 0, 0x31F do f:write(string.char(vm.lrd8(seg, i))) end
f:close()

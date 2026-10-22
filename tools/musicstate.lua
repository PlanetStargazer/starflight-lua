package.path = "src/?.lua;" .. package.path
local vm = require("vm")
local game = require("game")
local hw = require("hw")
local music = require("music")
game.boot("games/sf1")
for _, k in ipairs(require("keys").parse(arg[2] or "")) do hw.pushkey(k) end
local N = tonumber(arg[1])
local changes, last = 0, nil
local ev = 0
vm.set_trace(function()
    ev = ev + 1
    if ev % 3000 == 0 then music.tick()
        local seg = vm.rd16(0x5071)
        local st = seg ~= 0 and (vm.lrd8(seg, 2) .. "/" .. tostring(hw.sound.on) .. "/" .. tostring(hw.sound.divisor)) or "noseg"
        if st ~= last then changes = changes + 1; last = st; if changes < 15 then print(ev, st) end end
    end
end)
print(pcall(function() vm.run(N) end))
print("state changes", changes)

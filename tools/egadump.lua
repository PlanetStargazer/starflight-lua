package.path = "src/?.lua;" .. package.path
local vm = require("vm")
local game = require("game")
local hw = require("hw")
local ega = require("ega")
game.boot("games/sf1")
for c in (arg[2] or ""):gmatch(".") do hw.pushkey(c == "\n" and 13 or c:byte()) end
print(pcall(function() vm.run(tonumber(arg[1])) end))
for p = 0, 3 do
    local first, last, cnt = nil, nil, 0
    for o = 0, 0xFFFF do
        if ega.mem[p * 0x10000 + o] ~= 0 then first = first or o; last = o; cnt = cnt + 1 end
    end
    print("plane", p, "nonzero", cnt, first and string.format("%04X..%04X", first, last) or "-")
end
print("crtc 0C/0D", ega.crtc[0x0C], ega.crtc[0x0D], "gc", table.concat(ega.gc, ","))

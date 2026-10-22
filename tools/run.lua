-- headless runner for development:  luajit tools/run.lua [steps]
package.path = "src/?.lua;" .. package.path
local vm = require("vm")
local dos = require("dos")
local game = require("game")
game.boot("games/sf1")
local n = tonumber(arg[1]) or 1000000
local ok, err = pcall(function()
    local left = vm.run(n)
end)
print(ok, err)
print(string.format("si=%04X sp=%04X bp=%04X di=%04X", vm.getsi(), vm.getsp(), vm.getbp(), vm.getdi()))
-- dump the text screen
local m = vm.mem
for row = 0, 24 do
    local t = {}
    for col = 0, 79 do
        local c = m[0xB8000 + (row * 80 + col) * 2]
        t[#t + 1] = (c >= 32 and c < 127) and string.char(c) or " "
    end
    local s = table.concat(t):gsub("%s+$", "")
    if #s > 0 then print(row, s) end
end

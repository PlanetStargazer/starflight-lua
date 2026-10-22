-- luajit tools/words.lua steps keys : log distinct word names in order of first execution after the key press
package.path = "src/?.lua;" .. package.path
local vm = require("vm")
local game = require("game")
local hw = require("hw")
game.boot("games/sf1")
local names = vm.names
local ovn = require("names1ov")
local seen, order = {}, {}
local started = false
vm.set_trace(function(w, c)
    local pfa = w + 2
    if not seen[pfa] then
        seen[pfa] = true
        order[#order + 1] = string.format("%04X %s", pfa, names[pfa] or ovn[pfa] or "?")
    end
end)
-- run until the display-mode prompt, then press the keys
print(pcall(function() vm.run(300000) end))
for c in (arg[2] or ""):gmatch(".") do hw.pushkey(c == "\n" and 13 or c:byte()) end
local before = #order
print(pcall(function() vm.run(tonumber(arg[1])) end))
for i = before + 1, #order do io.write(order[i], " | ") end
print()

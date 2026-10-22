package.path = "src/?.lua;tools/?.lua;" .. package.path
local vm = require("vm"); local game = require("game"); local hw = require("hw")
game.boot("games/sf1", {patches = true})
for _, k in ipairs(require("keys").parse(arg[2] or "")) do hw.pushkey(k) end
local names, ovn = vm.names, require("names1ov")
local ring, n = {}, 0
vm.set_trace(function(w) n = n + 1; ring[n % 40] = string.format("%04X %s", w + 2, names[w + 2] or ovn[w + 2] or "?") end)
print(pcall(function() vm.run(tonumber(arg[1])) end))
for i = n - 39, n do if ring[i % 40] then print(ring[i % 40]) end end

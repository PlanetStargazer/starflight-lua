-- luajit tools/coverage.lua steps seedlist...: which primitives did random play execute?
package.path = "src/?.lua;tools/?.lua;" .. package.path
local vm = require("vm")
local game = require("game")
local hw = require("hw")
local count = {}
local names = vm.names
local function parse(s) return require("keys").parse(s) end
local function fuzzkeys(seed, n)
    local p = io.popen("python3 tools/fuzz.py " .. seed .. " " .. n); local s = p:read("*l"); p:close(); return s
end
for _, addr in ipairs((function() local t = {} for a in pairs(vm.P) do t[#t + 1] = a end return t end)()) do
    local f = vm.P[addr]
    vm.P[addr] = function(bx) count[addr] = (count[addr] or 0) + 1; return f(bx) end
end
for i = 2, #arg do
    game.boot("games/sf1")
    for _, k in ipairs(parse(fuzzkeys(tonumber(arg[i]), 600))) do hw.pushkey(k) end
    local ok, err = pcall(function() local left = tonumber(arg[1]); while left > 0 and not vm.halted do vm.run(1000000); left = left - 1000000; if vm.yield then break end end end)
    if not ok then print("seed", arg[i], "ERROR", err) end
end
local never = {}
for a in pairs(vm.P) do if not count[a] then never[#never + 1] = a end end
table.sort(never)
local out = {}
for _, a in ipairs(never) do out[#out + 1] = string.format("%04X %s", a, names[a] or "") end
print("never executed:", #never, "of", (function() local n = 0 for _ in pairs(vm.P) do n = n + 1 end return n end)())
print(table.concat(out, " | "))

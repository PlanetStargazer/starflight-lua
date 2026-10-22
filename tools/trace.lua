-- luajit tools/trace.lua steps [keys]  : run, then print the last executed words
package.path = "src/?.lua;" .. package.path
local vm = require("vm")
local game = require("game")
local hw = require("hw")
game.boot("games/sf1")
local keys = arg[2] or ""
for c in keys:gmatch(".") do hw.pushkey(c == "\n" and 13 or c:byte()) end
local names = vm.names
local ovn = require("names1ov")
local ring, rn = {}, 0
local N = 60
vm.set_trace(function(w, c)
    rn = rn + 1
    ring[rn % N] = {w, c}
end)
local ok, err = pcall(function() vm.run(tonumber(arg[1])) end)
print(ok, err)
for i = rn - N + 1, rn do
    local e = ring[i % N]
    if e then
        local pfa = e[1] + 2
        print(string.format("%04X %-18s code=%04X", pfa, names[pfa] or ovn[pfa] or "?", e[2]))
    end
end

-- return stack back-trace
local addrs = {}
for a, n in pairs(names) do addrs[#addrs + 1] = {a, n} end
for a, n in pairs(ovn) do addrs[#addrs + 1] = {a, n} end
table.sort(addrs, function(x, y) return x[1] < y[1] end)
local function nearest(a)
    local best
    for _, e in ipairs(addrs) do if e[1] <= a then best = e else break end end
    return best and (best[2] .. "+" .. (a - best[1])) or "?"
end
print("--- return stack ---")
local bp = vm.getbp()
for i = 0, 40 do
    local a = bp + i * 2
    if a >= 0xF800 then break end
    local ra = vm.rd16(a)
    print(string.format("%04X  %s", ra, nearest(ra)))
end

-- list own-code words of STARFLT.COM that still have no Lua primitive
package.path = "src/?.lua;" .. package.path
local vm = require("vm"); require("dos"); require("prims")
local f = io.popen("python3 /tmp/claude-1000/-home-stargazer-claude-projects-sf1/ee137fea-8e2e-4d9a-9d99-47ca741c02ef/scratchpad/tools/words.py")
f:read("*l")
for l in f:lines() do
    local a, n = l:match("^0x(%x+) (.*)$")
    a = tonumber(a, 16)
    if not vm.P[a] then io.write(string.format("%04X %s   ", a, n)) end
end
print()

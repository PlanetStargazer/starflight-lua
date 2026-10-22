package.path = "src/?.lua;tools/?.lua;" .. package.path
local vm=require("vm"); local game=require("game"); local snap=require("snap"); local T=require("thread")
game.boot("games/sf1",{patches=true}); snap.load("/var/tmp/snap_port")
print(pcall(game.cheat))
local function cfa(n) return T.cfa(n) end
local function dump(from, n) local t={} for i=0,n-1 do t[#t+1]=string.format("%02x",vm.rd8(from+i)) end return table.concat(t," ") end
vm.call(cfa("*PERSON")); vm.call(cfa(">C+S")); vm.call(cfa("IOPEN"))
for i=1,7 do print(i, dump(0x63EF,0x23)); vm.call(cfa("INEXT")) end
vm.call(cfa("ICLOSE"))
vm.call(cfa("*ASSIGN-CREW")); vm.call(cfa(">C+S")); print("assign", dump(0x63EF+0x11,18)); vm.call(cfa("ICLOSE"))
vm.call(cfa("*SHIP")); vm.call(cfa(">C+S")); print("ship", dump(0x63EF+0x11,0x30)); vm.call(cfa("ICLOSE"))

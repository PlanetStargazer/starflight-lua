-- headless: run N steps, feed keys, write the current screen as PPM
-- luajit tools/shot.lua out.ppm steps [keys-as-text]
package.path = "src/?.lua;tools/?.lua;" .. package.path
local vm = require("vm")
local game = require("game")
local video = require("video")
local ega = require("ega")
local hw = require("hw")
local ffi = require("ffi")
game.boot("games/sf1")
local out, steps, keys = arg[1], tonumber(arg[2]), arg[3] or ""
for _, k in ipairs(require("keys").parse(keys)) do hw.pushkey(k) end
local ok, err = pcall(function() vm.run(steps) end)
print(ok, err)
print(string.format("si=%04X sp=%04X bp=%04X mode=%s", vm.getsi(), vm.getsp(), vm.getbp(), video.mode))
local w, h, buf
if video.mode == "graphics" then
    w, h = 320, 200
    buf = ffi.new("uint8_t[?]", w * h * 4); ega.render(buf)
else
    w, h = 640, 400
    buf = ffi.new("uint8_t[?]", w * h * 4); video.render_text(buf)
end
local f = io.open(out, "wb")
f:write(string.format("P6\n%d %d\n255\n", w, h))
for i = 0, w * h - 1 do f:write(string.char(buf[i * 4], buf[i * 4 + 1], buf[i * 4 + 2])) end
f:close()

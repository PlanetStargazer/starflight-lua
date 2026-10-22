-- State snapshots for the dev tools: directory with memory, EGA state and bookkeeping.
local ffi = require("ffi")
local vm = require("vm")
local dos = require("dos")
local ega = require("ega")
local video = require("video")
local hw = require("hw")

local S = {}
local function wfile(path, data) local f = assert(io.open(path, "wb")); f:write(data); f:close() end
local function rfile(path) local f = assert(io.open(path, "rb")); local d = f:read("*a"); f:close(); return d end

local function ser(t)       -- tiny serializer for the small state tables
    local out = {}
    local function w(v)
        if type(v) == "table" then
            out[#out + 1] = "{"
            for k, x in pairs(v) do out[#out + 1] = "[" .. (type(k) == "string" and string.format("%q", k) or tostring(k)) .. "]="; w(x); out[#out + 1] = "," end
            out[#out + 1] = "}"
        elseif type(v) == "string" then out[#out + 1] = string.format("%q", v)
        else out[#out + 1] = tostring(v) end
    end
    w(t)
    return "return " .. table.concat(out)
end

function S.save(dir)
    os.execute("mkdir -p " .. dir)
    wfile(dir .. "/mem.bin", ffi.string(vm.mem, 0x120000))
    local e = ega.getstate()
    local planes = e.planes; e.planes = nil
    wfile(dir .. "/ega.bin", planes)
    local d = dos.getstate()
    local files = d.files; d.files = nil
    for letter, f in pairs(files) do wfile(dir .. "/file" .. letter .. ".bin", f.data); f.data = nil end
    local st = {ega = e, dos = d, files = files, mode = video.mode, cursor = video.cursor,
        sound = {on = hw.sound.on, divisor = hw.sound.divisor, freq = hw.sound.freq},
        si = vm.getsi(), sp = vm.getsp(), bp = vm.getbp(), di = vm.getdi()}
    wfile(dir .. "/state.lua", ser(st))
end

function S.load(dir)
    ffi.copy(vm.mem, rfile(dir .. "/mem.bin"), 0x120000)
    local st = assert(loadstring(rfile(dir .. "/state.lua")))()
    st.ega.planes = rfile(dir .. "/ega.bin")
    ega.setstate(st.ega)
    for letter, f in pairs(st.files) do f.data = rfile(dir .. "/file" .. letter .. ".bin") end
    st.dos.files = st.files
    dos.setstate(st.dos)
    video.mode = st.mode; video.cursor = st.cursor
    hw.sound.on, hw.sound.divisor, hw.sound.freq = st.sound.on, st.sound.divisor, st.sound.freq
    vm.setsi(st.si); vm.setsp(st.sp); vm.setbp(st.bp); vm.set_di(st.di)
    return st
end

return S

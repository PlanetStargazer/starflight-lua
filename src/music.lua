-- Timer-tick services.
--
-- Starflight hooks INT 1Ch (the 18.2 Hz BIOS timer tick) to play its music: the
-- MUSIC overlay copies a small block of machine code and note tables into a far
-- segment (MUSSEG) and points the vector there.  The routine below is a port
-- of that interrupt handler (MUSSEG:00FF); it walks the song tables and
-- programs the PC speaker.
--
-- layout of the block (offsets in MUSSEG):
--   02 playing flag      05 current phrase entry    07 current note pointer
--   09 repeat counter    0A tick counter            0B note length
--   0C rest length       0D 1 while silent          0E entry offset of this routine
--   24 table of 8253 divisors, two bytes per note number

local vm = require("vm")
local hw = require("hw")
local lrd8, lwr8, lrd16, lwr16 = vm.lrd8, vm.lwr8, vm.lrd16, vm.lwr16
local band = require("bit").band

local M = {}
local MUSSEG = 0x5071
local remixmusic = nil
pcall(function() remixmusic = require("remixmusic") end)

local function speaker_off() hw.sound.on = false; hw.music.on = false end
local function speaker_on(divisor)
    hw.sound.divisor = divisor
    hw.sound.freq = divisor > 0 and 1193182 / divisor or 0
    if M.is_remix and M.is_remix() then
        hw.sound.on = false
        hw.music.on = false
        if remixmusic and not remixmusic.is_playing() then
            remixmusic.play()
        end
    else
        hw.sound.on = true
        hw.music.freq = hw.sound.freq; hw.music.on = true
        if remixmusic and remixmusic.is_playing() then
            remixmusic.stop()
        end
    end
end

local function isr(s)
    if lrd8(s, 2) == 0 then return end
    local counter = band(lrd8(s, 0x0A) - 1, 0xFF)
    lwr8(s, 0x0A, counter)
    if counter ~= 0 then return end
    local function set_counter_silent(v)             -- L12b
        lwr8(s, 0x0A, v); speaker_off(); lwr8(s, 0x0D, 1)
    end
    -- L11d: a rest follows the sounding part of the note
    if lrd8(s, 0x0D) == 0 and lrd8(s, 0x0C) ~= 0 then
        set_counter_silent(lrd8(s, 0x0C)); return
    end
    while true do
        -- L137: fetch the next note
        local si = lrd16(s, 0x07)
        local al = band(lrd8(s, si), 0x7F); local raw = lrd8(s, si)
        si = si + 1
        if al ~= 0 then
            local rest = 0
            if band(al, 0x40) ~= 0 then al = band(al, 0x3F); rest = 1 end
            lwr8(s, 0x0B, al); lwr8(s, 0x0C, rest)
            local note = lrd8(s, si); si = si + 1
            lwr16(s, 0x07, si)
            if note == 0xFF then
                set_counter_silent(lrd8(s, 0x0B)); return
            end
            lwr8(s, 0x0A, band(lrd8(s, 0x0B) - lrd8(s, 0x0C), 0xFF))
            speaker_on(lrd16(s, 0x24 + note * 2))
            lwr8(s, 0x0D, 0)
            return
        end
        -- L17b: end of phrase
        si = lrd16(s, 0x05)
        local rep = band(lrd8(s, 0x09) - 1, 0xFF)
        lwr8(s, 0x09, rep)
        if rep == 0 then
            si = si + 3
            local nxt = lrd8(s, si)
            if nxt == 0 then lwr16(s, 0x02, 0); return end      -- song finished
            lwr16(s, 0x05, si); lwr8(s, 0x09, nxt)
        end
        lwr16(s, 0x07, lrd16(s, si + 1))
        lwr8(s, 0x0A, 1); lwr8(s, 0x0D, 1)
    end
end

-- silence the song that is playing (the game's own music words are not involved)
function M.stop()
    local s = vm.rd16(MUSSEG)
    if s ~= 0 then lwr8(s, 2, 0) end
    speaker_off()
    if remixmusic then remixmusic.stop() end
end

-- true while a song is running
function M.playing()
    local s = vm.rd16(MUSSEG)
    return s ~= 0 and lrd8(s, 2) ~= 0
end

function M.sync_remix()
    if M.playing() then
        if M.is_remix and M.is_remix() then
            hw.music.on = false
            if remixmusic and not remixmusic.is_playing() then
                remixmusic.play()
            end
        else
            if remixmusic and remixmusic.is_playing() then
                remixmusic.stop()
            end
            hw.music.on = true
        end
    end
end

-- called 18.2 times a second; services the INT 1Ch vector if it is the music routine
function M.tick()
    local mem = vm.mem
    local off = mem[0x70] + mem[0x71] * 256
    local seg = mem[0x72] + mem[0x73] * 256
    local s = vm.rd16(MUSSEG)
    if seg ~= 0 and seg == s and off == lrd16(s, 0x0E) then
        isr(s)
        if lrd8(s, 2) == 0 then
            hw.music.on = false
            if remixmusic then remixmusic.stop() end
        end
    end
end

return M

-- Sound synthesis for the front end.  The game only drives the PC speaker; this turns what it
-- programs into something richer, in three layers:
--   music    the monophonic song voice is played as an FM lead with a soft octave-down bass and a
--            detuned pad, shaped by a per-note envelope and a small reverb
--   effects  TONE/BEEP sounds get the same FM timbre, plus noise for fast sweeps (lasers, explosions)
--            and a rumble for very low tones
--   extras   (optional) interface blips for the keyboard and a quiet ambience bed per screen
local S = {}

local RATE = 44100
local TAU = math.pi * 2
local sin, abs, floor, min, max = math.sin, math.abs, math.floor, math.min, math.max

local seed = 12345
local function noise()
    seed = (seed * 16807) % 2147483647
    return seed / 1073741823.5 - 1
end

local function blep(t, dt)
    if t < dt then t = t / dt; return t + t - t * t - 1
    elseif t > 1 - dt then t = (t - 1) / dt; return t * t + t + t + 1 end
    return 0
end
local function saw(ph, dt) return 2 * ph - 1 - blep(ph, dt) end
local function tri(ph) return ph < 0.5 and 4 * ph - 1 or 3 - 4 * ph end

-- ---------------------------------------------------------------------------
-- reverb: four combs and two all-passes (Schroeder), scaled to the sample rate
-- ---------------------------------------------------------------------------
local function delay(n) local d = {n = n, i = 0}; for k = 0, n - 1 do d[k] = 0 end; return d end
local combs = {}
for _, n in ipairs{1557, 1617, 1491, 1422} do combs[#combs + 1] = {d = delay(n), lp = 0} end
local aps = {delay(225), delay(556)}
local function reverb(x)
    local sum = 0
    for _, c in ipairs(combs) do
        local d = c.d
        local y = d[d.i]
        c.lp = c.lp + (y - c.lp) * 0.45                   -- damping
        d[d.i] = x + c.lp * 0.80
        d.i = (d.i + 1) % d.n
        sum = sum + y
    end
    sum = sum * 0.25
    for _, d in ipairs(aps) do
        local y = d[d.i]
        local out = -sum + y
        d[d.i] = sum + y * 0.5
        d.i = (d.i + 1) % d.n
        sum = out
    end
    return sum
end

-- ---------------------------------------------------------------------------
-- music voice
-- ---------------------------------------------------------------------------
local m = {freq = 0, on = false, t = 0, gain = 0, p1 = 0, p2 = 0, p3 = 0, p4 = 0, lp = 0, f = 0}
local function music_sample(freq, on)
    -- note on: new pitch (or the speaker switched on again) restarts the envelope
    if on and (not m.on or abs(freq - m.freq) > 0.5) then m.t = 0 end
    m.on, m.freq = on, on and freq or m.freq
    local target = on and 1 or 0
    m.gain = m.gain + (target - m.gain) * (on and 0.02 or 0.0004)      -- ~1 ms attack, ~60 ms release
    if m.gain < 0.0004 then return 0 end
    local f = m.freq
    local t = m.t
    m.t = t + 1 / RATE
    local vib = 1 + 0.004 * sin(TAU * 5.5 * t) * min(1, t * 3)         -- vibrato fades in on held notes
    f = f * vib
    local dt1 = f / RATE
    m.p1 = (m.p1 + dt1) % 1
    -- FM lead: the modulation index decays, so every note starts bright and mellows
    local idx = 0.5 + 2.2 * math.exp(-t * 7)
    m.p2 = (m.p2 + dt1 * 2) % 1
    local lead = sin(TAU * m.p1 + idx * sin(TAU * m.p2))
    -- bass: triangle an octave down
    m.p3 = (m.p3 + dt1 * 0.5) % 1
    local bass = tri(m.p3) * min(1, t * 25) * (f > 90 and 1 or 0)
    -- pad: two detuned saws, slow attack
    local d2, d3 = dt1 * 1.006, dt1 * 0.994
    m.p4 = (m.p4 + d2) % 1
    m.p5 = ((m.p5 or 0) + d3) % 1
    local pad = (saw(m.p4, d2) + saw(m.p5, d3)) * 0.5 * min(1, t * 8)
    local decay = 0.72 + 0.28 * math.exp(-t * 6)                         -- gentle decay to the sustain level
    local v = (lead * 0.62 + bass * 0.28 + pad * 0.22) * decay * m.gain
    m.lp = m.lp + (v - m.lp) * 0.35                                      -- tame the top end
    return m.lp
end

-- ---------------------------------------------------------------------------
-- effect voice (TONE / BEEP): FM tone, noise for sweeps, rumble for very low tones
-- ---------------------------------------------------------------------------
local e = {on = false, gain = 0, f = 0, pf = 0, p1 = 0, p2 = 0, t = 0, sweep = 0, nlp = 0, lp = 0, rum = 0}
local function fx_sample(freq, on)
    if on and not e.on then e.t = 0; e.f = freq end
    e.on = on
    e.gain = e.gain + ((on and 1 or 0) - e.gain) * (on and 0.03 or 0.003)
    if e.gain < 0.0005 then e.pf = freq; return 0 end
    local dt = 1 / RATE
    e.t = e.t + dt
    if on then
        local prev = e.f
        e.f = e.f + (freq - e.f) * 0.01                 -- glide so jumps do not click
        e.sweep = e.sweep * 0.9995 + abs(e.f - prev) / max(prev, 50) * 40
    end
    local f = max(e.f, 20)
    local dt1 = f / RATE
    e.p1 = (e.p1 + dt1) % 1
    e.p2 = (e.p2 + dt1 * 1.5) % 1
    local idx = 1.0 + min(e.sweep, 6)
    local tone = sin(TAU * e.p1 + idx * sin(TAU * e.p2))
    local nz = noise()
    e.nlp = e.nlp + (nz - e.nlp) * (f < 200 and 0.06 or 0.4)
    local v = tone * 0.6
    v = v + nz * min(e.sweep, 1) * 0.25                   -- fast pitch sweeps: hiss/crackle
    if f < 220 then v = v + e.nlp * 1.6 * (1 - f / 220) end  -- very low tones: rumble
    v = v * e.gain
    e.lp = e.lp + (v - e.lp) * 0.4
    return e.lp
end

-- ---------------------------------------------------------------------------
-- extras: interface blips and ambience
-- ---------------------------------------------------------------------------
local blips = {}
local BLIPS = {
    tick = {{f = 1900, len = 0.012, gain = 0.10}},
    ok   = {{f = 880, len = 0.05, gain = 0.12}, {f = 1320, len = 0.08, gain = 0.12, at = 0.05}},
    back = {{f = 520, len = 0.07, gain = 0.12}},
}
function S.blip(kind)
    local def = BLIPS[kind]
    if not def then return end
    for _, b in ipairs(def) do blips[#blips + 1] = {f = b.f, len = b.len, gain = b.gain, t = -(b.at or 0), p = 0} end
    if #blips > 12 then table.remove(blips, 1) end
end
local function blip_sample()
    local v = 0
    for i = #blips, 1, -1 do
        local b = blips[i]
        b.t = b.t + 1 / RATE
        if b.t >= b.len then table.remove(blips, i)
        elseif b.t >= 0 then
            b.p = (b.p + b.f / RATE) % 1
            v = v + sin(TAU * b.p) * b.gain * (1 - b.t / b.len) ^ 2
        end
    end
    return v
end

local amb = {kind = nil, level = 0, lp1 = 0, lp2 = 0, p = 0, lfo = 0}
local AMB = {                           -- hum frequency, noise brightness (0..1), loudness
    flight  = {hum = 55,  bright = 0.03, vol = 0.05},
    orbit   = {hum = 48,  bright = 0.02, vol = 0.035},
    surface = {hum = 0,   bright = 0.015, vol = 0.07, wind = true},
    port    = {hum = 60,  bright = 0.01, vol = 0.03},
}
local function amb_sample(kind)
    local want = kind and 1 or 0
    amb.level = amb.level + (want - amb.level) * 0.00005                 -- fade over about half a second
    if kind and kind ~= amb.kind then amb.kind = kind end
    local a = AMB[amb.kind or ""]
    if not a or amb.level < 0.001 then return 0 end
    local nz = noise()
    amb.lp1 = amb.lp1 + (nz - amb.lp1) * a.bright
    local v = amb.lp1 * 8
    if a.hum > 0 then
        amb.p = (amb.p + a.hum / RATE) % 1
        v = v * 0.5 + sin(TAU * amb.p) * 0.5 + sin(TAU * amb.p * 2.01) * 0.15
    end
    if a.wind then
        amb.lfo = (amb.lfo + 0.13 / RATE) % 1
        v = v * (0.6 + 0.4 * sin(TAU * amb.lfo))
    end
    return v * a.vol * amb.level
end

-- Which ambience belongs to the overlay that is currently loaded (value of OV#).
local OVERLAY_AMBIENCE = {
    [0x8747] = "flight", [0x87A0] = nil,            -- HYPER-OV: system / hyperspace flight
    [0x8186] = "orbit", [0x8325] = "orbit", [0x965B] = "orbit",   -- ORBIT-OV, CAPTAIN, LAND-OV
    [0x8CFA] = "surface", [0x7BA4] = "surface", [0x7FB7] = "surface",   -- terrain vehicle screens
    [0x7660] = "port",                              -- PORTMENU-OV
}
function S.ambience_for(ov) return OVERLAY_AMBIENCE[ov] end

-- ---------------------------------------------------------------------------
-- render n samples into setter(i, value)
--   st: music = {on, freq}, fx = {on, freq}, amb = kind or nil, extras = bool
-- ---------------------------------------------------------------------------
function S.render(n, setter, st)
    local mo, mf = st.music.on and st.music.freq > 20 and st.music.freq < 8000, st.music.freq
    local fo, ff = st.fx.on and st.fx.freq > 20 and st.fx.freq < 18000, st.fx.freq
    local extras, kind = st.extras, st.amb
    for i = 0, n - 1 do
        local mv = music_sample(mf, mo)
        local fv = fx_sample(ff, fo)
        local dry = mv + fv
        local wet = reverb(dry * 0.5)
        local out = dry * 0.55 + wet * 0.5
        if extras then out = out + blip_sample() + amb_sample(kind) else amb.level = 0 end
        setter(i, max(-1, min(1, out)))
    end
end

return S

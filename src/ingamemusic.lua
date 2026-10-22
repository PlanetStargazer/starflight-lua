local M = {}

local TRACKS = {"starbase", "space", "hyperspace", "orbit", "surface"}
local sources = {}
local volumes = {}
local current_track = nil
local in_hyperspace = false

local OVERLAY_MAP = {
    [0x7660] = "starbase",                               -- PORTMENU-OV: Starport / Starbase
    [0x8186] = "orbit", [0x8325] = "orbit", [0x965B] = "orbit", -- ORBIT-OV, CAPTAIN, LAND-OV
    [0x8CFA] = "surface", [0x7BA4] = "surface", [0x7FB7] = "surface", -- Terrain vehicle screens
}

function M.init()
    for _, name in ipairs(TRACKS) do
        if not sources[name] then
            local path = "audio/" .. name .. ".ogg"
            if love.filesystem.getInfo(path) then
                local ok, src = pcall(love.audio.newSource, path, "stream")
                if ok and src then
                    src:setLooping(true)
                    src:setVolume(0)
                    sources[name] = src
                    volumes[name] = 0
                end
            end
        end
    end
end

function M.set_hyperspace(val)
    in_hyperspace = val
end

function M.get_track_for(ov)
    if not ov or ov == 0 then return nil end
    local direct = OVERLAY_MAP[ov]
    if direct then return direct end
    if ov == 0x8747 then -- HYPER-OV: system flight or hyperspace
        return in_hyperspace and "hyperspace" or "space"
    end
    return nil
end

function M.update(dt, ov, enabled, in_game)
    M.init()

    if ov == 0x7660 then
        in_hyperspace = false
    end

    local target = nil
    if enabled and in_game then
        target = M.get_track_for(ov)
        -- If currently in a transition overlay (like menus/comms), retain previous ambient track if playing
        if not target and current_track and (ov == 0x7E41 or ov == 0x7008 or ov == 0x8907) then
            target = current_track
        end
    end

    if target ~= current_track then
        current_track = target
    end

    local TARGET_VOL = 0.40 -- gentle, non-intrusive ambient background volume
    local FADE_SPEED = 0.8  -- fade speed per second

    for _, name in ipairs(TRACKS) do
        local src = sources[name]
        if src then
            local want_vol = (name == current_track) and TARGET_VOL or 0.0
            local cur_vol = volumes[name] or 0.0

            if cur_vol < want_vol then
                cur_vol = math.min(want_vol, cur_vol + dt * FADE_SPEED)
            elseif cur_vol > want_vol then
                cur_vol = math.max(want_vol, cur_vol - dt * FADE_SPEED)
            end
            volumes[name] = cur_vol

            if cur_vol > 0.001 then
                src:setVolume(cur_vol)
                if not src:isPlaying() then
                    src:play()
                end
            else
                src:setVolume(0)
                if src:isPlaying() then
                    src:stop()
                end
            end
        end
    end
end

function M.stop_all()
    for _, name in ipairs(TRACKS) do
        local src = sources[name]
        if src then
            src:stop()
            src:setVolume(0)
        end
        volumes[name] = 0
    end
    current_track = nil
end

return M

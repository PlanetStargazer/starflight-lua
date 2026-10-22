local M = {}

local source = nil
local active = false

function M.init()
    if not source then
        local p = "intro_remix.ogg"
        if love.filesystem.getInfo(p) then
            local ok, s = pcall(love.audio.newSource, p, "stream")
            if ok then source = s end
        end
    end
end

function M.play()
    M.init()
    if source then
        source:stop()
        source:seek(0)
        source:play()
        active = true
    end
end

function M.stop()
    if source then
        source:stop()
    end
    active = false
end

function M.is_playing()
    return source and source:isPlaying() or false
end

return M

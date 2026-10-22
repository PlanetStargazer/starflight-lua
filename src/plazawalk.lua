-- Click-to-walk in the starport rotunda.  The astronaut is moved with the arrow keys, one step of 6 game
-- pixels each, and a facility opens when ENTER is pressed on one of the blue-grey door mats (the game reads
-- the colour of the picture under him).  A click starts a walk towards the clicked point: every step takes
-- the direction that gets closest, avoiding steps that did not work before and places visited often; a
-- click on a mat (dark grey with blue stripes, on the floor) opens it as soon as he stands on a mat
-- near the click (the game keeps the door code of the picture under him in ECED).
local M = {}

local KEY = {up = 0x4800, down = 0x5000, left = 0x4B00, right = 0x4D00, enter = 13}
local STEP = 6
local DELTA = {up = {0, STEP}, down = {0, -STEP}, left = {-STEP, 0}, right = {STEP, 0}}
local SPRITE_W, SPRITE_H = 9, 12          -- the astronaut's picture, in game pixels
local MAT_GREY = "85,85,85"
-- the floor of the rotunda in the 320x200 picture: an ellipse (walls and the outer ring are grey too)
local FLOOR_CX, FLOOR_CY, FLOOR_RX, FLOOR_RY = 160, 122, 154, 44

local task, last_key_t = nil, 0

local function on_floor(px, py)
    return ((px - FLOOR_CX) / FLOOR_RX) ^ 2 + ((py - FLOOR_CY) / FLOOR_RY) ^ 2 <= 1
end

-- is the picture under (px, py) a door mat?  raw(px, py) gives "r,g,b".
local function mat_at(px, py, raw)
    if not on_floor(px, py) then return false end
    local grey = 0
    for dy = -2, 2 do
        for dx = -4, 4, 2 do
            if raw(px + dx, py + dy) == MAT_GREY then grey = grey + 1 end
        end
    end
    return grey >= 4
end

M.mat_at = mat_at                       -- for the tests

-- start walking towards the click at (gx, gy) (game pixels, y counted from the bottom)
function M.click(gx, gy, raw)
    local enter = mat_at(math.floor(gx * 2), 199 - math.floor(gy), raw)
    -- the astronaut's position is the top left of his picture; the click is where his feet go
    task = {tx = gx - SPRITE_W / 2, ty = gy + SPRITE_H, enter = enter, blocked = {}, visits = {}, steps = 0}
    return true
end

function M.cancel() task = nil end
function M.busy() return task ~= nil end

-- called every frame with the current time, the astronaut's position, the door code of the mat under him
-- (0 when he is not on one) and a function that presses a key
function M.update(now, x, y, region, press)
    if not task or now - last_key_t < 0.14 then return end
    local here = x .. "," .. y
    if task.last and task.last.at == here then task.blocked[here .. task.last.dir] = true end   -- the step did not happen
    local dist = math.sqrt((x - task.tx) ^ 2 + (y - task.ty) ^ 2)
    if task.enter and region ~= 0 and dist <= 2.5 * STEP then       -- on a mat close to the click: open it
        press(KEY.enter)
        task = nil
        return
    end
    if dist <= STEP * 0.8 and not task.enter then task = nil; return end
    if not task.best or dist < task.best - 2 then task.best, task.best_step = dist, task.steps    -- still getting closer
    elseif task.steps - task.best_step > 12 then task = nil; return end                          -- going round in circles
    task.visits[here] = (task.visits[here] or 0) + 1
    task.steps = task.steps + 1
    local best, bs
    for dir, d in pairs(DELTA) do
        if not task.blocked[here .. dir] then
            local nx, ny = x + d[1], y + d[2]
            local score = math.sqrt((nx - task.tx) ^ 2 + (ny - task.ty) ^ 2) + 7 * (task.visits[nx .. "," .. ny] or 0)
            if not bs or score < bs then best, bs = dir, score end
        end
    end
    if not best or task.steps > (task.enter and 60 or 40) then task = nil; return end
    task.last = {at = here, dir = best}
    press(KEY[best])
    last_key_t = now
end

return M

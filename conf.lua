function love.conf(t)
    t.identity = "starflight-lua"
    t.window.title = "Starflight"
    t.window.width = 960
    t.window.height = 600
    t.window.resizable = true
    t.window.vsync = 1
    t.modules.physics = false
    t.modules.video = false
    t.modules.touch = false
end

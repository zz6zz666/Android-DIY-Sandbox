function love.conf(t)
  t.identity = "syscheck"
  t.window.title = "Love System Check"

  t.modules.joystick = true
  t.modules.thread = true
  t.audio.mic = true
end

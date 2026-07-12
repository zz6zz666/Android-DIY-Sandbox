function love.conf(t)
  t.identity = "syscheck"
  t.window.title = "LOVE SysCheck"
  t.modules.joystick = true
  t.modules.thread = true
  t.modules.data = true
  t.audio.mic = true
end

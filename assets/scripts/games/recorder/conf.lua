function love.conf(t)
  t.identity = "recorder"
  t.window.title = "录音机"
  t.modules.audio = true
  t.modules.sound = true
  t.modules.graphics = true
  t.modules.window = true
  t.modules.timer = true
  t.modules.event = true
  t.modules.touch = true
  t.modules.mouse = true
  t.modules.system = true
  t.modules.font = true
  t.audio.mic = true
end

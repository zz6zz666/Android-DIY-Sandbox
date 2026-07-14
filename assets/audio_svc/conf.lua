function love.conf(t)
  t.identity = "audio_svc"
  t.window.title = "Audio Service"

  t.modules.window = true
  t.modules.graphics = true
  t.modules.audio = true
  t.modules.sound = true
  t.modules.data = true
  t.modules.timer = true
  t.modules.event = true
  t.modules.mouse = false
  t.modules.keyboard = false
  t.modules.joystick = false
  t.modules.touch = false
  t.modules.font = false
  t.modules.image = false
  t.modules.video = false
  t.modules.system = false
  t.modules.physics = false
  t.modules.thread = false

  t.audio.mic = true
end

function love.conf(t)
  t.identity = "physics"
  t.window.title = "Box2D Physics Demo"
  t.modules.window = true
  t.modules.graphics = true
  t.modules.audio = false
  t.modules.sound = false
  t.modules.data = true
  t.modules.timer = true
  t.modules.event = true
  t.modules.mouse = true
  t.modules.keyboard = false
  t.modules.joystick = false
  t.modules.touch = true
  t.modules.font = true
  t.modules.image = false
  t.modules.video = false
  t.modules.system = true
  t.modules.physics = true
  t.modules.thread = false
end

-- 传感器 demo: 加速度计滚动小球 + 陀螺仪方向显示
local host = require("love_host")

local sensorActive = false
local ax, ay, az = 0, 0, 0  -- accelerometer
local gx, gy, gz = 0, 0, 0  -- gyroscope

local ball = { x = 200, y = 200, r = 30, vx = 0, vy = 0 }

local function start()
  sensorActive = true
  host.sensor_start({ accel = true, gyro = true })
end

local function stop()
  sensorActive = false
  host.sensor_stop()
  ax, ay, az = 0, 0, 0
  gx, gy, gz = 0, 0, 0
end

function love.load()
  host.on("sensor_accel", function(d)
    ax = d.x or 0; ay = d.y or 0; az = d.z or 0
  end)
  host.on("sensor_gyro", function(d)
    gx = d.x or 0; gy = d.y or 0; gz = d.z or 0
  end)
  start()
end

function love.update(dt)
  local w, h = love.graphics.getDimensions()
  -- 加速度驱动小球运动 (倾斜手机)
  ball.vx = ball.vx + ax * dt * 300
  ball.vy = ball.vy + ay * dt * 300
  ball.vx = ball.vx * (1 - dt * 3)  -- 摩擦
  ball.vy = ball.vy * (1 - dt * 3)
  ball.x = ball.x + ball.vx * dt
  ball.y = ball.y + ball.vy * dt
  ball.x = math.max(ball.r, math.min(w - ball.r, ball.x))
  ball.y = math.max(ball.r, math.min(h - ball.r, ball.y))
end

function love.draw()
  local w, h = love.graphics.getDimensions()
  love.graphics.clear(0.06, 0.08, 0.14)

  love.graphics.setColor(0.5, 0.8, 1.0)
  love.graphics.circle("fill", ball.x, ball.y, ball.r)

  -- 标题
  love.graphics.setColor(1, 1, 1)
  love.graphics.setNewFont(16)
  love.graphics.print("LOVE Sensor Demo", 12, 10)

  -- 传感器开关
  love.graphics.setColor(sensorActive and {0.3, 1, 0.4} or {1, 0.3, 0.3})
  love.graphics.print(sensorActive and "SENSORS: ON (tap to stop)" or "SENSORS: OFF (tap to start)", 12, 32)

  -- 加速度计数据
  love.graphics.setColor(0.7, 1, 0.7)
  love.graphics.print(string.format("Accel  x=%.2f  y=%.2f  z=%.2f", ax, ay, az), 12, 58)

  -- 陀螺仪数据
  love.graphics.setColor(1, 0.7, 0.7)
  love.graphics.print(string.format("Gyro   x=%.2f  y=%.2f  z=%.2f", gx, gy, gz), 12, 78)

  -- 提示
  love.graphics.setColor(1, 1, 1, 0.5)
  love.graphics.print("Tilt phone to move ball   Tap to toggle sensors", 12, h - 20)
end

function love.touchpressed(id, x, y)
  if sensorActive then stop() else start() end
end

require("love_host")

local world
local bodies = {}
local groundBody

local function wall(x, y, w, h)
  local body = love.physics.newBody(world, x + w / 2, y + h / 2, "static")
  local shape = love.physics.newRectangleShape(0, 0, w, h)
  local fixture = love.physics.newFixture(body, shape)
  fixture:setRestitution(0.6)
  return body
end

local function spawnCircle(px, py)
  local body = love.physics.newBody(world, px, py, "dynamic")
  local r = love.math.random(12, 30)
  local shape = love.physics.newCircleShape(r)
  local fixture = love.physics.newFixture(body, shape)
  fixture:setRestitution(0.5)
  body:setAngularVelocity(love.math.random() * 4 - 2)
  bodies[#bodies + 1] = body
  return body
end

function love.load()
  love.physics.setMeter(64)
  local w, h = love.graphics.getDimensions()
  world = love.physics.newWorld(0, 9.81 * 64, true)

  local wallThick = 32
  wall(w / 2, h + wallThick / 2, w, wallThick)
  wall(-wallThick / 2, h / 2, wallThick, h)
  wall(w + wallThick / 2, h / 2, wallThick, h)

  for i = 1, 8 do
    spawnCircle(love.math.random(60, w - 60), love.math.random(20, 160))
  end
end

function love.update(dt)
  world:update(math.min(dt, 1 / 30))
  for i = #bodies, 1, -1 do
    local x, y = bodies[i]:getPosition()
    local _, h = love.graphics.getDimensions()
    if y > h + 200 then
      bodies[i]:destroy()
      table.remove(bodies, i)
    end
  end
end

function love.draw()
  local w, h = love.graphics.getDimensions()
  love.graphics.clear(0.06, 0.07, 0.14)
  love.graphics.setColor(0.16, 0.18, 0.26)
  love.graphics.rectangle("fill", 0, h - 28, w, 28)
  love.graphics.setColor(1, 1, 1, 0.7)
  love.graphics.print(string.format("Box2D Physics  objects: %d  fps: %d", #bodies, love.timer.getFPS()), 8, 8)
  love.graphics.setColor(1, 1, 1, 0.4)
  love.graphics.print("Tap to spawn balls   gravity: 9.81 m/s^2", 8, 24)
  for _, body in ipairs(bodies) do
    local x, y = body:getPosition()
    local shape = body:getFixtures()[1]:getShape()
    if shape:typeOf("CircleShape") then
      local r = shape:getRadius()
      love.graphics.setColor(0.4, 0.56, 1.0, 0.8)
      love.graphics.circle("fill", x, y, r)
    end
  end
end

function love.touchpressed(id, px, py)
  local w, h = love.graphics.getDimensions()
  if px <= 1.0 and py <= 1.0 then px, py = px * w, py * h end
  spawnCircle(px, py)
end

function love.mousepressed(px, py, button, istouch)
  if not istouch then
    local w, h = love.graphics.getDimensions()
    if px <= 1.0 and py <= 1.0 then px, py = px * w, py * h end
    spawnCircle(px, py)
  end
end

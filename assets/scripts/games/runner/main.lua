-- runner.love: tap to jump over obstacles
local player, obstacles, score, groundY, speed, spawn, gameover

local function reset()
  local w, h = love.graphics.getDimensions()
  groundY = h * 0.78
  player = { x = w * 0.18, y = groundY, vy = 0, size = 30, onGround = true }
  obstacles = {}
  score = 0
  speed = 260
  spawn = 1.0
  gameover = false
end

local function jump()
  if gameover then reset(); return end
  if player.onGround then
    player.vy = -640
    player.onGround = false
  end
end

function love.load() reset() end
function love.touchpressed(id, x, y) jump() end
function love.mousepressed(x, y, b) jump() end
function love.keypressed(k) if k == "space" then jump() end end

function love.update(dt)
  if gameover then return end
  local w, h = love.graphics.getDimensions()
  groundY = h * 0.78

  player.vy = player.vy + 1700 * dt
  player.y = player.y + player.vy * dt
  if player.y >= groundY then player.y = groundY; player.vy = 0; player.onGround = true end

  spawn = spawn - dt
  if spawn <= 0 then
    spawn = 0.8 + math.random() * 0.7
    table.insert(obstacles, { x = w + 20, w = 18 + math.random(18), h = 26 + math.random(34) })
  end

  for i = #obstacles, 1, -1 do
    local o = obstacles[i]
    o.x = o.x - speed * dt
    if o.x + o.w < 0 then
      table.remove(obstacles, i); score = score + 1
    else
      local px1, py1 = player.x - player.size/2, player.y - player.size
      local px2, py2 = player.x + player.size/2, player.y
      local ox1, oy1 = o.x, groundY - o.h
      local ox2, oy2 = o.x + o.w, groundY
      if px1 < ox2 and px2 > ox1 and py1 < oy2 and py2 > oy1 then gameover = true end
    end
  end
  speed = speed + dt * 8
end

function love.draw()
  local w, h = love.graphics.getDimensions()
  love.graphics.clear(0.53, 0.81, 0.92)
  love.graphics.setColor(0.30, 0.68, 0.32)
  love.graphics.rectangle("fill", 0, groundY, w, h - groundY)
  love.graphics.setColor(0.18, 0.18, 0.24)
  love.graphics.rectangle("fill", player.x - player.size/2, player.y - player.size, player.size, player.size)
  love.graphics.setColor(0.65, 0.20, 0.20)
  for _, o in ipairs(obstacles) do
    love.graphics.rectangle("fill", o.x, groundY - o.h, o.w, o.h)
  end
  love.graphics.setColor(1, 1, 1)
  love.graphics.print("Score: " .. score, 8, 8)
  love.graphics.print("TAP to jump", 8, 24)
  if gameover then
    love.graphics.print("CRASHED! tap to restart", 8, 44)
  end
end

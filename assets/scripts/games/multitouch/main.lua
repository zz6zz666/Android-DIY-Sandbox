require("love_host")

local fingers = {}
local COLORS = {
  {1.0, 0.3, 0.3}, {0.3, 0.9, 0.3}, {0.3, 0.5, 1.0}, {1.0, 0.9, 0.2},
  {1.0, 0.4, 0.8}, {0.3, 1.0, 0.8}, {1.0, 0.6, 0.2}, {0.6, 0.3, 1.0},
}

function love.load()
  local w, h = love.graphics.getDimensions()
  love.window.setTitle("MultiTouch Test " .. w .. "x" .. h)
end

function love.touchpressed(id, x, y, dx, dy, p)
  local w, h = love.graphics.getDimensions()
  if x <= 1.0 and y <= 1.0 then x, y = x * w, y * h end
  local idKey = tostring(id)
  local ci = 1
  for _ in pairs(fingers) do ci = ci + 1 end
  fingers[idKey] = {
    x = x, y = y,
    color = COLORS[((ci - 1) % #COLORS) + 1],
  }
end

function love.touchmoved(id, x, y, dx, dy, p)
  local f = fingers[tostring(id)]
  if not f then return end
  local w, h = love.graphics.getDimensions()
  if x <= 1.0 and y <= 1.0 then x, y = x * w, y * h end
  f.x, f.y = x, y
end

function love.touchreleased(id, x, y, dx, dy, p)
  fingers[tostring(id)] = nil
end

function love.draw()
  local w, h = love.graphics.getDimensions()
  love.graphics.clear(0.06, 0.07, 0.14)

  local count = 0
  for _ in pairs(fingers) do count = count + 1 end
  local r = math.min(w, h) * 0.07

  for id, f in pairs(fingers) do
    local c = f.color
    love.graphics.setColor(c[1], c[2], c[3], 0.5)
    love.graphics.circle("fill", f.x, f.y, r)
    love.graphics.setColor(c[1], c[2], c[3], 0.85)
    love.graphics.circle("line", f.x, f.y, r)
    love.graphics.setColor(1, 1, 1, 0.9)
    love.graphics.print(tostring(id), f.x - 12, f.y - 8)
  end

  love.graphics.setColor(1, 1, 1, 0.7)
  love.graphics.print(string.format("active fingers: %d", count), 8, 8)
  love.graphics.setColor(1, 1, 1, 0.4)
  love.graphics.print("multi-touch demo", 8, 26)
end

function love.update(dt) end

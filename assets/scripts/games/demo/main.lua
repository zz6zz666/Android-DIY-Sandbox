-- demo.love: colorful rotating shapes
require("love_host")   -- 启用挂起冻结(freeze)所需的 love.run 包装
local t = 0
local colors = {
  {1,0.2,0.3}, {0.2,1,0.4}, {0.2,0.5,1}, {1,0.9,0.2}, {0.8,0.2,1}
}
function love.update(dt) t = t + dt end
function love.draw()
  local w,h = love.graphics.getDimensions()
  love.graphics.clear(0.05,0.05,0.1)
  for i=1,5 do
    local a = t * 0.8 + i * 1.256
    local c = colors[i]
    local r = 50 + math.sin(t*1.7 + i)*20
    love.graphics.setColor(c)
    love.graphics.push()
    love.graphics.translate(w/2 + math.cos(a)*(w/4), h/2 + math.sin(a*1.3)*(h/4))
    love.graphics.rotate(t*2 + i)
    love.graphics.polygon("fill", 0,-r, r*0.7,r*0.4, -r*0.7,r*0.4)
    love.graphics.pop()
  end
  love.graphics.setColor(1,1,1)
  love.graphics.print("DEMO pid="..love.system.getOS(), 8, 8)
  love.graphics.print("fps:"..love.timer.getFPS(), 8, 24)
end
